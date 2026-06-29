package members

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"
)

const DefaultLease = 30 * time.Second

type Server struct {
	mu      sync.Mutex
	lease   time.Duration
	clock   func() time.Time
	network map[string]map[string]*Member
	secure  *secureCodec
	replays map[string]time.Time
}

type Member struct {
	DeviceID  string    `json:"deviceId"`
	Nickname  string    `json:"nickname"`
	IP        string    `json:"ip"`
	LastSeen  time.Time `json:"lastSeen"`
	ExpiresAt time.Time `json:"expiresAt"`
}

type leaseRequest struct {
	NetworkID   string `json:"networkId"`
	DeviceID    string `json:"deviceId"`
	Nickname    string `json:"nickname"`
	RequestedIP string `json:"requestedIp"`
	Subnet      string `json:"subnet"`
}

type releaseRequest struct {
	NetworkID string `json:"networkId"`
	DeviceID  string `json:"deviceId"`
}

type leaseResponse struct {
	IP           string    `json:"ip"`
	CIDR         string    `json:"cidr"`
	LeaseSeconds int       `json:"leaseSeconds"`
	ExpiresAt    time.Time `json:"expiresAt"`
	Members      []Member  `json:"members"`
}

func NewServer(lease time.Duration) *Server {
	server, _ := NewServerWithSharedSecret(lease, "")
	return server
}

func NewServerWithSharedSecret(lease time.Duration, sharedSecret string) (*Server, error) {
	if lease <= 0 {
		lease = DefaultLease
	}
	server := &Server{
		lease:   lease,
		clock:   time.Now,
		network: make(map[string]map[string]*Member),
		replays: make(map[string]time.Time),
	}
	codec, err := newSecureCodec(sharedSecret, server.clock)
	if err != nil {
		return nil, err
	}
	server.secure = codec
	return server, nil
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /v1/lease", s.handleLease)
	mux.HandleFunc("POST /v1/heartbeat", s.handleLease)
	mux.HandleFunc("POST /v1/release", s.handleRelease)
	mux.HandleFunc("GET /v1/members", s.handleMembers)
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte("ok\n"))
	})
	return logRequests(mux)
}

func (s *Server) ListenAndServe(addr string) error {
	if strings.TrimSpace(addr) == "" {
		addr = ":51874"
	}
	return http.ListenAndServe(addr, s.Handler())
}

func (s *Server) handleLease(w http.ResponseWriter, r *http.Request) {
	var req leaseRequest
	if err := s.decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	if err := validateLease(req); err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}

	member, members, err := s.upsertLease(req)
	if err != nil {
		writeError(w, http.StatusConflict, err)
		return
	}
	s.writeJSON(w, leaseResponse{
		IP:           member.IP,
		CIDR:         member.IP + "/24",
		LeaseSeconds: int(s.lease.Seconds()),
		ExpiresAt:    member.ExpiresAt,
		Members:      members,
	})
}

func (s *Server) handleRelease(w http.ResponseWriter, r *http.Request) {
	var req releaseRequest
	if err := s.decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	if req.NetworkID == "" || req.DeviceID == "" {
		writeError(w, http.StatusBadRequest, errors.New("networkId and deviceId are required"))
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if devices := s.network[req.NetworkID]; devices != nil {
		delete(devices, req.DeviceID)
		if len(devices) == 0 {
			delete(s.network, req.NetworkID)
		}
	}
	if s.secure != nil {
		s.writeJSON(w, map[string]bool{"ok": true})
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleMembers(w http.ResponseWriter, r *http.Request) {
	if s.secure != nil {
		writeError(w, http.StatusBadRequest, errors.New("encrypted member service requires POST lease or heartbeat"))
		return
	}
	networkID := r.URL.Query().Get("networkId")
	if networkID == "" {
		writeError(w, http.StatusBadRequest, errors.New("networkId is required"))
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.expireLocked(networkID)
	s.writeJSON(w, map[string]any{"members": s.membersLocked(networkID)})
}

func (s *Server) upsertLease(req leaseRequest) (Member, []Member, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.expireLocked(req.NetworkID)

	devices := s.network[req.NetworkID]
	if devices == nil {
		devices = make(map[string]*Member)
		s.network[req.NetworkID] = devices
	}

	ip := req.RequestedIP
	if current := devices[req.DeviceID]; current != nil && current.IP != "" {
		ip = current.IP
	}
	if ip == "" || s.ipInUseLocked(req.NetworkID, req.DeviceID, ip) {
		var err error
		ip, err = s.allocateIPLocked(req.NetworkID, req.DeviceID, req.Subnet)
		if err != nil {
			return Member{}, nil, err
		}
	}

	now := s.clock().UTC()
	member := &Member{
		DeviceID:  req.DeviceID,
		Nickname:  strings.TrimSpace(req.Nickname),
		IP:        ip,
		LastSeen:  now,
		ExpiresAt: now.Add(s.lease),
	}
	if member.Nickname == "" {
		member.Nickname = "GoN2N"
	}
	devices[req.DeviceID] = member
	return *member, s.membersLocked(req.NetworkID), nil
}

func (s *Server) expireLocked(networkID string) {
	now := s.clock().UTC()
	for deviceID, member := range s.network[networkID] {
		if !member.ExpiresAt.After(now) {
			delete(s.network[networkID], deviceID)
		}
	}
}

func (s *Server) membersLocked(networkID string) []Member {
	devices := s.network[networkID]
	members := make([]Member, 0, len(devices))
	for _, member := range devices {
		members = append(members, *member)
	}
	sort.Slice(members, func(i, j int) bool {
		return members[i].IP < members[j].IP
	})
	return members
}

func (s *Server) ipInUseLocked(networkID, deviceID, ip string) bool {
	for otherID, member := range s.network[networkID] {
		if otherID != deviceID && member.IP == ip {
			return true
		}
	}
	return false
}

func (s *Server) allocateIPLocked(networkID, deviceID, subnet string) (string, error) {
	prefix, err := subnetPrefix(subnet)
	if err != nil {
		return "", err
	}
	for host := 10; host <= 250; host++ {
		ip := fmt.Sprintf("%s.%d", prefix, host)
		if !s.ipInUseLocked(networkID, deviceID, ip) {
			return ip, nil
		}
	}
	return "", errors.New("no available IP in subnet")
}

func validateLease(req leaseRequest) error {
	if req.NetworkID == "" {
		return errors.New("networkId is required")
	}
	if req.DeviceID == "" {
		return errors.New("deviceId is required")
	}
	if _, err := subnetPrefix(req.Subnet); err != nil {
		return err
	}
	if req.RequestedIP != "" && net.ParseIP(req.RequestedIP).To4() == nil {
		return errors.New("requestedIp must be an IPv4 address")
	}
	return nil
}

func subnetPrefix(subnet string) (string, error) {
	ip, network, err := net.ParseCIDR(subnet)
	if err != nil || ip.To4() == nil {
		return "", errors.New("subnet must be an IPv4 CIDR such as 10.239.180.0/24")
	}
	ones, bits := network.Mask.Size()
	if ones != 24 || bits != 32 {
		return "", errors.New("only /24 subnets are supported")
	}
	ip4 := network.IP.To4()
	return fmt.Sprintf("%d.%d.%d", ip4[0], ip4[1], ip4[2]), nil
}

func (s *Server) decodeJSON(r *http.Request, target any) error {
	defer r.Body.Close()
	data, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		return err
	}
	if s.secure != nil {
		replayID, err := s.secure.open(data, target)
		if err != nil {
			return err
		}
		if s.seenReplay(replayID) {
			return errors.New("encrypted envelope replay detected")
		}
		return nil
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	return decoder.Decode(target)
}

func (s *Server) writeJSON(w http.ResponseWriter, value any) {
	w.Header().Set("Content-Type", "application/json")
	if s.secure != nil {
		data, err := s.secure.seal(value)
		if err != nil {
			log.Printf("encrypt response: %v", err)
			http.Error(w, "encrypt response", http.StatusInternalServerError)
			return
		}
		_, err = w.Write(append(data, '\n'))
		if err != nil {
			log.Printf("write response: %v", err)
		}
		return
	}
	if err := json.NewEncoder(w).Encode(value); err != nil {
		log.Printf("write response: %v", err)
	}
}

func (s *Server) seenReplay(replayID string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.clock().UTC()
	for id, expiresAt := range s.replays {
		if !expiresAt.After(now) {
			delete(s.replays, id)
		}
	}
	if _, exists := s.replays[replayID]; exists {
		return true
	}
	s.replays[replayID] = now.Add(secureEnvelopeMaxAge)
	return false
}

func writeError(w http.ResponseWriter, status int, err error) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
}

func logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		log.Printf("%s %s", r.Method, r.URL.RequestURI())
		next.ServeHTTP(w, r)
	})
}
