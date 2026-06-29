package members

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestEncryptedLease(t *testing.T) {
	server, err := NewServerWithSharedSecret(DefaultLease, "shared secret")
	if err != nil {
		t.Fatal(err)
	}
	server.clock = func() time.Time { return time.Unix(1700000000, 0).UTC() }
	server.secure.now = server.clock

	requestBody, err := server.secure.seal(leaseRequest{
		NetworkID:   "network",
		DeviceID:    "device-a",
		Nickname:    "A",
		RequestedIP: "10.239.180.18",
		Subnet:      "10.239.180.0/24",
	})
	if err != nil {
		t.Fatal(err)
	}

	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/v1/lease", bytes.NewReader(requestBody))
	server.Handler().ServeHTTP(recorder, request)
	if recorder.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d: %s", recorder.Code, recorder.Body.String())
	}

	var response leaseResponse
	if _, err := server.secure.open(recorder.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if response.IP != "10.239.180.18" {
		t.Fatalf("expected leased IP, got %q", response.IP)
	}
	if len(response.Members) != 1 || response.Members[0].DeviceID != "device-a" {
		t.Fatalf("unexpected members: %#v", response.Members)
	}
}

func TestEncryptedLeaseRejectsReplay(t *testing.T) {
	server, err := NewServerWithSharedSecret(DefaultLease, "shared secret")
	if err != nil {
		t.Fatal(err)
	}
	server.clock = func() time.Time { return time.Unix(1700000000, 0).UTC() }
	server.secure.now = server.clock

	requestBody, err := server.secure.seal(leaseRequest{
		NetworkID:   "network",
		DeviceID:    "device-a",
		RequestedIP: "10.239.180.18",
		Subnet:      "10.239.180.0/24",
	})
	if err != nil {
		t.Fatal(err)
	}
	handler := server.Handler()
	for i := 0; i < 2; i++ {
		recorder := httptest.NewRecorder()
		request := httptest.NewRequest(http.MethodPost, "/v1/lease", bytes.NewReader(requestBody))
		handler.ServeHTTP(recorder, request)
		if i == 0 && recorder.Code != http.StatusOK {
			t.Fatalf("first request status = %d", recorder.Code)
		}
		if i == 1 && recorder.Code != http.StatusBadRequest {
			t.Fatalf("replay status = %d", recorder.Code)
		}
	}
}

func TestPlainLeaseStillWorksWithoutSharedSecret(t *testing.T) {
	server := NewServer(DefaultLease)
	body, err := json.Marshal(leaseRequest{
		NetworkID:   "network",
		DeviceID:    "device-a",
		RequestedIP: "10.239.180.18",
		Subnet:      "10.239.180.0/24",
	})
	if err != nil {
		t.Fatal(err)
	}

	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/v1/lease", bytes.NewReader(body))
	server.Handler().ServeHTTP(recorder, request)
	if recorder.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d: %s", recorder.Code, recorder.Body.String())
	}
}
