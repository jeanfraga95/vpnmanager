package main

import (
	"crypto/subtle"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"os"
	"os/exec"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/crypto/bcrypt"
)

// ---- protocolo DTProto (CloudJF SSH_BHTTP / libgojni DTunnel0/DTProto) ----
const (
	dtpTypeAuth     = 1 // C->S payload = usuario+senha concatenados
	dtpTypeAuthResp = 2 // S->C payload = [status u8][msg]
	dtpTypeIP       = 3 // C->S vazio pede IP; S->C payload = 4B IPv4 ou 16B IPv6
	dtpTypeData     = 4 // ambos: pacote IP cru (TUN)
	dtpTypeKA       = 5 // C->S keepalive vazio
)

var (
	dtpClientHello = []byte("DTUNNEL/1.1 CLIENT_HELLO\r\n")
	dtpServerHello = []byte("DTUNNEL/1.1 SERVER_HELLO\r\n")
)

const (
	dtpNet      = "10.8.0."
	dtpMaxPay   = 65536
	tunDevice   = "/dev/net/tun"
	tunIface    = "dtp0"
	tunSetIFF   = 0x400454ca
	iFF_TUN     = 0x0001
	iFF_NO_PI   = 0x1000
	sysIoctlArm = 29
)

type dtpUserFile struct {
	Version int `json:"version"`
	Users   []struct {
		Username     string `json:"username"`
		PasswordHash string `json:"password_hash"`
	} `json:"users"`
}

var (
	dtpUsersFile = "/etc/VPNManager/dragontcp/users.json"
	dtpTunName  = "dtp0"

	dtpUsersMu sync.RWMutex
	dtpUsers   = map[string]string{}

	dtpOnce      sync.Once
	dtpTun       *os.File
	dtpReadyErr  error
	dtpRoutesMu  sync.Mutex
	dtpRoutes    = map[uint32]*dtPeer{}
	dtpNextHosts = map[uint32]time.Time{} // host -> livre em
)

type dtPeer struct {
	c    net.Conn
	user string
	ip   uint32
}

func dtpLoadUsers(path string) {
	b, err := os.ReadFile(path)
	if err != nil {
		log.Printf("dtproto: sem arquivo de usuarios %s: %v", path, err)
		return
	}
	var uf dtpUserFile
	if err := json.Unmarshal(b, &uf); err != nil {
		log.Printf("dtproto: users.json invalido: %v", err)
		return
	}
	dtpUsersMu.Lock()
	for _, u := range uf.Users {
		if u.Username != "" && u.PasswordHash != "" {
			dtpUsers[u.Username] = u.PasswordHash
		}
	}
	n := len(dtpUsers)
	dtpUsersMu.Unlock()
	log.Printf("dtproto: %d usuarios carregados de %s", n, path)
}

func dtpCheck(cred []byte) (string, bool) {
	if len(cred) == 0 || len(cred) > 512 {
		return "", false
	}
	dtpUsersMu.RLock()
	defer dtpUsersMu.RUnlock()
	for u, h := range dtpUsers {
		if len(cred) > len(u) && strings.HasPrefix(string(cred), u) {
			pass := string(cred[len(u):])
			if bcrypt.CompareHashAndPassword([]byte(h), []byte(pass)) == nil {
				return u, true
			}
		}
	}
	return "", false
}

func dtpSetup() error {
	fd, err := syscall.Open(tunDevice, syscall.O_RDWR, 0)
	if err != nil {
		return fmt.Errorf("abrir %s: %w", tunDevice, err)
	}
	var ifr struct {
		name  [16]byte
		flags uint16
	}
	copy(ifr.name[:], dtpTunName)
	ifr.flags = iFF_TUN | iFF_NO_PI
	_, _, errno := syscall.Syscall(sysIoctlArm, uintptr(fd), uintptr(tunSetIFF), uintptr(unsafe.Pointer(&ifr)))
	if errno != 0 {
		syscall.Close(fd)
		return fmt.Errorf("ioctl TUNSETIFF: %v", errno)
	}
	f := os.NewFile(uintptr(fd), tunIface)
	run := func(name string, args ...string) {
		cmd := exec.Command(name, args...)
		out, err := cmd.CombinedOutput()
		if err != nil {
			vlog("dtproto setup: %s %v: %s", name, args, out)
		}
	}
	run("ip", "addr", "show", "dev", tunIface)
	exec.Command("ip", "addr", "add", "10.8.0.1/24", "dev", dtpTunName).Run()
	run("ip", "link", "set", "dev", dtpTunName, "mtu", "1400", "up")
	exec.Command("sysctl", "-w", "net.ipv4.ip_forward=1").Run()
	dev := strings.TrimSpace(dtpDefaultDev())
	if dev == "" {
		dev = "eth0"
	}
	exec.Command("iptables", "-t", "nat", "-C", "POSTROUTING", "-s", "10.8.0.0/24", "-o", dev, "-j", "MASQUERADE").Run()
	exec.Command("iptables", "-t", "nat", "-A", "POSTROUTING", "-s", "10.8.0.0/24", "-o", dev, "-j", "MASQUERADE").Run()
	exec.Command("iptables", "-C", "FORWARD", "-i", dev, "-o", dtpTunName, "-m", "state", "--state", "RELATED,ESTABLISHED", "-j", "ACCEPT").Run()
	exec.Command("iptables", "-A", "FORWARD", "-i", dev, "-o", dtpTunName, "-m", "state", "--state", "RELATED,ESTABLISHED", "-j", "ACCEPT").Run()
	exec.Command("iptables", "-C", "FORWARD", "-i", dtpTunName, "-o", dev, "-j", "ACCEPT").Run()
	exec.Command("iptables", "-A", "FORWARD", "-i", dtpTunName, "-o", dev, "-j", "ACCEPT").Run()
	dtpTun = f
	go dtpTunReader()
	log.Printf("dtproto: TUN %s no ar (10.8.0.1/24, nat via %s)", tunIface, dev)
	return nil
}

func dtpDefaultDev() string {
	b, err := exec.Command("ip", "route", "show", "default").Output()
	if err != nil {
		return ""
	}
	for _, f := range strings.Fields(string(b)) {
		if f == "dev" {
			continue
		}
	}
	fs := strings.Fields(string(b))
	for i, f := range fs {
		if f == "dev" && i+1 < len(fs) {
			return fs[i+1]
		}
	}
	return ""
}

func dtpEnsure() error {
	dtpOnce.Do(func() { dtpReadyErr = dtpSetup() })
	return dtpReadyErr
}

func dtpTunReader() {
	buf := make([]byte, 65536)
	for {
		if dtpTun == nil {
			time.Sleep(time.Second)
			continue
		}
		n, err := dtpTun.Read(buf)
		if err != nil {
			log.Printf("dtproto: erro lendo TUN: %v", err)
			time.Sleep(time.Second)
			continue
		}
		pkt := buf[:n]
		if n < 20 || pkt[0]>>4 != 4 {
			continue
		}
		dst := binary.BigEndian.Uint32(pkt[16:20])
		dtpRoutesMu.Lock()
		peer := dtpRoutes[dst]
		dtpRoutesMu.Unlock()
		if peer == nil {
			continue
		}
		if _, err := peer.c.Write(dtpPkt(dtpTypeData, pkt)); err != nil {
			vlog("dtproto: falha enviando p/ %s: %v", peer.user, err)
		}
	}
}

func dtpAllocIP(user string, c net.Conn) uint32 {
	dtpRoutesMu.Lock()
	defer dtpRoutesMu.Unlock()
	now := time.Now()
	for host := uint32(2); host < 255; host++ {
		if _, taken := dtpRoutes[host]; taken {
			if t, ok := dtpNextHosts[host]; ok && now.Before(t.Add(90*time.Second)) {
				continue
			}
		}
		ip := 0x0A080000 | host // 10.8.0.host
		dtpRoutes[ip] = &dtPeer{c: c, user: user, ip: ip}
		dtpNextHosts[host] = now
		return ip
	}
	return 0
}

func dtpFreeIP(c net.Conn) {
	dtpRoutesMu.Lock()
	defer dtpRoutesMu.Unlock()
	for ip, p := range dtpRoutes {
		if p.c == c {
			delete(dtpRoutes, ip)
		}
	}
}

func dtpPkt(typ byte, payload []byte) []byte {
	b := make([]byte, 6+len(payload))
	b[0] = typ
	b[1] = 0
	binary.BigEndian.PutUint32(b[2:], uint32(len(payload)))
	copy(b[6:], payload)
	return b
}

func dtpReadFull(c net.Conn, n int) ([]byte, error) {
	b := make([]byte, n)
	off := 0
	for off < n {
		m, err := c.Read(b[off:])
		if m > 0 {
			off += m
		}
		if err != nil {
			return nil, err
		}
	}
	return b, nil
}

// serveDTProto fala o protocolo do cliente CloudJF sobre um stream ja estabelecido.
func serveDTProto(c net.Conn) {
	defer func() {
		dtpFreeIP(c)
		c.Close()
	}()
	if err := dtpEnsure(); err != nil {
		log.Printf("dtproto: TUN indisponivel: %v", err)
		return
	}
	// hello: le ate \r\n (max 64B). O 4.6.7 manda 26B fixos, o 5.0.0
	// aparenta mandar outra coisa — logar sempre o bruto.
	var hello []byte
	hb := make([]byte, 1)
	for len(hello) < 64 {
		if _, err := c.Read(hb); err != nil {
			vlog("dtproto: fim antes do hello: %v", err)
			return
		}
		hello = append(hello, hb[0])
		if len(hello) >= 2 && hello[len(hello)-2] == '\r' && hello[len(hello)-1] == '\n' {
			break
		}
	}
	log.Printf("dtproto: hello bruto (%dB): %q", len(hello), hello)
	if !strings.Contains(string(hello), "CLIENT_HELLO") {
		log.Printf("dtproto: hello nao reconhecido, encerrando")
		return
	}
	if _, err := c.Write(dtpServerHello); err != nil {
		vlog("dtproto: falha escrevendo server hello: %v", err)
		return
	}
	vlog("dtproto: handshake ok")
	user := ""
	authed := false
	for {
		hdr, err := dtpReadFull(c, 6)
		if err != nil {
			vlog("dtproto: fim (%s): %v", user, err)
			return
		}
		typ := hdr[0]
		n := binary.BigEndian.Uint32(hdr[2:])
		if n > dtpMaxPay {
			log.Printf("dtproto: payload muito grande (%d) de %s", n, user)
			return
		}
		pl := []byte{}
		if n > 0 {
			if pl, err = dtpReadFull(c, int(n)); err != nil {
				return
			}
		}
		switch typ {
		case dtpTypeAuth:
			u, ok := dtpCheck(pl)
			if ok {
				user = u
				authed = true
				log.Printf("dtproto: autenticado usuario=%s", u)
				if _, err := c.Write(dtpPkt(dtpTypeAuthResp, []byte{1, 'O', 'K'})); err != nil {
					return
				}
			} else {
				log.Printf("dtproto: credencial invalida (%d bytes)", len(pl))
				c.Write(dtpPkt(dtpTypeAuthResp, []byte{0, 'f', 'a', 'i', 'l'}))
				return
			}
		case dtpTypeIP:
			if !authed {
				return
			}
			ip := dtpAllocIP(user, c)
			if ip == 0 {
				log.Printf("dtproto: pool de IPs esgotado")
				return
			}
			b := make([]byte, 4)
			binary.BigEndian.PutUint32(b, ip)
			vlog("dtproto: IP atribuido %s -> %d.%d.%d.%d", user, b[0], b[1], b[2], b[3])
			if _, err := c.Write(dtpPkt(dtpTypeIP, b)); err != nil {
				return
			}
		case dtpTypeData:
			if !authed || dtpTun == nil {
				continue
			}
			if len(pl) >= 20 {
				src := binary.BigEndian.Uint32(pl[12:16])
				dtpRoutesMu.Lock()
				p := dtpRoutes[src]
				dtpRoutesMu.Unlock()
				if p != nil && subtle.ConstantTimeCompare([]byte(p.user), []byte(user)) != 1 {
					continue // pacote com IP de outra sessao
				}
			}
			if _, err := dtpTun.Write(pl); err != nil {
				vlog("dtproto: falha escrevendo no TUN: %v", err)
			}
		case dtpTypeKA:
			// ignora
		default:
			vlog("dtproto: tipo desconhecido %d (%d bytes)", typ, n)
		}
	}
}
