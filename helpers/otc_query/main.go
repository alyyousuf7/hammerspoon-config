// Long-lived OTC poller. Holds one MySQL connection and prints a JSON line of
// recent OTC tokens every OTC_POLL_SECS. Hammerspoon launches this once and
// consumes stdout via streamingCallback. Replaces the old node helper (query.js)
// — same streaming contract, but a ~5MB static binary instead of a 40MB node
// runtime + node_modules + a hard-coded fnm node path.
//
// Credentials and interval come from env vars set by the caller (see
// config/otc_codes.lua). No args.
package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	_ "github.com/go-sql-driver/mysql"
)

const query = `SELECT t.token, t.email, CAST(UNIX_TIMESTAMP(t.created_at) AS SIGNED) AS created_ts
                 FROM email_tokens t
                 JOIN (
                   SELECT email, MAX(created_at) AS mx
                     FROM email_tokens
                    WHERE created_at >= NOW() - INTERVAL 15 MINUTE
                    GROUP BY email
                 ) latest
                   ON latest.email = t.email AND latest.mx = t.created_at
                ORDER BY t.created_at DESC
                LIMIT 10`

type row struct {
	Token     string `json:"token"`
	Email     string `json:"email"`
	CreatedTS int64  `json:"created_ts"`
}

func emit(v any) {
	b, err := json.Marshal(v)
	if err != nil {
		return
	}
	os.Stdout.Write(append(b, '\n'))
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func dsn() string {
	return fmt.Sprintf("%s:%s@tcp(%s:%s)/%s?timeout=3s&readTimeout=3s",
		env("MYSQL_USER", ""), env("MYSQL_PASS", ""),
		env("MYSQL_HOST", "127.0.0.1"), env("MYSQL_PORT", "3306"),
		env("MYSQL_DB", ""))
}

func main() {
	pollSecs, _ := strconv.Atoi(env("OTC_POLL_SECS", "5"))
	if pollSecs <= 0 {
		pollSecs = 5
	}

	// Clean exit when Hammerspoon kills us on reload.
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
	go func() { <-sig; os.Exit(0) }()

	var db *sql.DB

	// Reconnect lazily on any error — MySQL drops idle connections, laptop
	// sleeps, VPN flaps. Cheaper than reconnecting every poll.
	tick := func() {
		var err error
		if db == nil {
			db, err = sql.Open("mysql", dsn())
			if err != nil {
				emit(map[string]any{"ok": false, "error": err.Error()})
				db = nil
				return
			}
			db.SetMaxOpenConns(1)
			db.SetConnMaxIdleTime(5 * time.Minute)
		}
		rows, err := db.Query(query)
		if err != nil {
			emit(map[string]any{"ok": false, "error": err.Error()})
			db.Close()
			db = nil
			return
		}
		out := []row{}
		for rows.Next() {
			var r row
			if err := rows.Scan(&r.Token, &r.Email, &r.CreatedTS); err != nil {
				continue
			}
			out = append(out, r)
		}
		rows.Close()
		emit(map[string]any{"ok": true, "rows": out})
	}

	tick()
	t := time.NewTicker(time.Duration(pollSecs) * time.Second)
	defer t.Stop()
	for range t.C {
		tick()
	}
}
