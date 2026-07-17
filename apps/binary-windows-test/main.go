// win-bin — binary_buildpack Windows route-integrity test app.
// Pure stdlib, single file. Cross-compiles to a Windows exe (see build.sh).
//
// Endpoints:
//   /whoami   - what the app sees at the socket + HTTP layer
//   /callout  - c2c driver: GET http://<target><path> and return the result
//   /health   - "ok"
//   /         - index
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"time"
)

func env(k string) string { return os.Getenv(k) }

// whoami: pre-upgrade RemoteAddr = gorouter/cell IP; post-upgrade = 127.0.0.1.
// X-Forwarded-For is unchanged either way.
func whoami(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]string{
		"remote_addr":             r.RemoteAddr,
		"x_forwarded_for":         r.Header.Get("X-Forwarded-For"),
		"x_forwarded_proto":       r.Header.Get("X-Forwarded-Proto"),
		"x_forwarded_client_cert": r.Header.Get("X-Forwarded-Client-Cert"),
		"host":                    r.Host,
		"cf_instance_index":       env("CF_INSTANCE_INDEX"),
		"cf_instance_ip":          env("CF_INSTANCE_IP"),
		"cf_instance_internal_ip": env("CF_INSTANCE_INTERNAL_IP"),
		"port":                    env("PORT"),
	})
}

// callout: c2c goes straight to the app port over the overlay, bypassing the
// route-integrity proxy, so it should behave the same before and after upgrade.
func callout(w http.ResponseWriter, r *http.Request) {
	target := r.URL.Query().Get("target")
	path := r.URL.Query().Get("path")
	if path == "" {
		path = "/whoami"
	}
	url := "http://" + target + path
	w.Header().Set("Content-Type", "application/json")
	resp, err := (&http.Client{Timeout: 10 * time.Second}).Get(url)
	if err != nil {
		_ = json.NewEncoder(w).Encode(map[string]interface{}{"ok": false, "url": url, "error": err.Error()})
		return
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	_ = json.NewEncoder(w).Encode(map[string]interface{}{"ok": true, "url": url, "status": resp.StatusCode, "body": string(body)})
}

func main() {
	port := env("PORT")
	if port == "" {
		port = "8080"
	}
	http.HandleFunc("/whoami", whoami)
	http.HandleFunc("/callout", callout)
	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, "ok") })
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, "win-bin test app: /whoami /callout /health")
	})
	fmt.Println("listening on 0.0.0.0:" + port)
	_ = http.ListenAndServe("0.0.0.0:"+port, nil)
}
