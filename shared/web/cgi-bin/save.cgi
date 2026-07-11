#!/bin/sh
# Receives folder settings posted from the status page and drops the
# raw body into the inbox. All parsing and validation happens on the
# NAS host (roon-server-docker.sh apply-pending, run by cron) — this
# CGI deliberately does nothing else and has no access to the host.
echo "Content-Type: text/plain; charset=utf-8"
echo ""
if [ "$REQUEST_METHOD" = "POST" ] && [ -n "$CONTENT_LENGTH" ] \
   && [ "$CONTENT_LENGTH" -gt 0 ] && [ "$CONTENT_LENGTH" -le 4096 ] 2>/dev/null; then
    head -c "$CONTENT_LENGTH" > /www/inbox/pending.tmp 2>/dev/null \
        && mv /www/inbox/pending.tmp /www/inbox/pending.conf \
        && { echo "OK"; exit 0; }
fi
echo "ERROR"
