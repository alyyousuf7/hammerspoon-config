#!/usr/bin/env node
// Long-lived helper: holds one MySQL connection and prints a JSON line of
// recent OTC tokens every POLL_SECS. Hammerspoon launches this once and
// consumes stdout via streamingCallback. Replaces a per-poll fork that
// caused multi-GB memory growth in Hammerspoon over time.
//
// Credentials and interval are read from env vars set by the caller.

const mysql = require("mysql2/promise");

const POLL_SECS = Number(process.env.OTC_POLL_SECS || 5);

const SQL = `SELECT t.token, t.email, UNIX_TIMESTAMP(t.created_at) AS created_ts
               FROM email_tokens t
               JOIN (
                 SELECT email, MAX(created_at) AS mx
                   FROM email_tokens
                  WHERE created_at >= NOW() - INTERVAL 30 MINUTE
                  GROUP BY email
               ) latest
                 ON latest.email = t.email AND latest.mx = t.created_at
              ORDER BY t.created_at DESC
              LIMIT 10`;

function emit(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n");
}

async function connect() {
  return mysql.createConnection({
    host: process.env.MYSQL_HOST,
    port: Number(process.env.MYSQL_PORT || 3306),
    user: process.env.MYSQL_USER,
    password: process.env.MYSQL_PASS,
    database: process.env.MYSQL_DB,
    connectTimeout: 3000,
  });
}

(async () => {
  let conn = null;

  // Reconnect lazily on any error — MySQL drops idle connections, laptop
  // sleeps, VPN flaps. Cheaper than reconnecting every poll.
  async function tick() {
    try {
      if (!conn) conn = await connect();
      const [rows] = await conn.execute(SQL);
      emit({ ok: true, rows });
    } catch (e) {
      emit({ ok: false, error: String(e.message || e) });
      if (conn) {
        try { await conn.end(); } catch (_) {}
        conn = null;
      }
    }
  }

  // Exit cleanly when Hammerspoon kills us on reload.
  process.on("SIGTERM", () => process.exit(0));
  process.on("SIGINT",  () => process.exit(0));

  await tick();
  setInterval(tick, POLL_SECS * 1000);
})();
