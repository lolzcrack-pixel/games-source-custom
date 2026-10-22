#!/bin/bash

AUTO_RESTART_ON_CRASH=${AUTO_RESTART_ON_CRASH:-1}
RESTART_ON_CLEAN_EXIT=${RESTART_ON_CLEAN_EXIT:-1}
CRASH_RESTART_DELAY=${CRASH_RESTART_DELAY:-10}
CRASH_MAX_RESTARTS=${CRASH_MAX_RESTARTS:-5}
CRASH_WINDOW=${CRASH_WINDOW:-600}

RESTART_INTERVAL_HOURS=${RESTART_INTERVAL_HOURS:-24}
RESTART_TIMES=${RESTART_TIMES:-}
RESTART_WARNINGS=${RESTART_WARNINGS:-600,300,60,30,10,5}
RESTART_WARNING_CMD=${RESTART_WARNING_CMD:-say [AVISO] El servidor se reiniciara en %TIME%}
RESTART_STOP_CMD=${RESTART_STOP_CMD:-quit}

STOP_COMMANDS=${STOP_COMMANDS:-quit,exit}
STOP_TIMEOUT=${STOP_TIMEOUT:-30}
CONSOLE_PTY=${CONSOLE_PTY:-1}

TZ=${TZ:-UTC}
export TZ

FIFO=/tmp/.server_console
USER_STOP_FLAG=/tmp/.wrapper_user_stop
SCHEDULED_FLAG=/tmp/.wrapper_scheduled_restart

SERVER_PID=""
SCHEDULER_PID=""
CRASH_TIMES=()

log() {
    echo -e "\033[1;36m[Wrapper]\033[0m $*"
}

trim() {
    local s="${1//$'\r'/}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

zzz() {
    sleep "$1" &
    SLEEP_PID=$!
    wait "$SLEEP_PID"
}

fmt_time() {
    local s=$1
    if (( s >= 3600 && s % 3600 == 0 )); then
        (( s == 3600 )) && echo "1 hora" || echo "$(( s / 3600 )) horas"
    elif (( s >= 60 && s % 60 == 0 )); then
        (( s == 60 )) && echo "1 minuto" || echo "$(( s / 60 )) minutos"
    else
        (( s == 1 )) && echo "1 segundo" || echo "${s} segundos"
    fi
}

send_cmd() {
    log "Consola > $1"
    printf '%s\n' "$1" >&3
}

kill_server() {
    [ -n "$SERVER_PID" ] && kill -"$1" -- -"$SERVER_PID" 2>/dev/null
}

kill_orphans() {
    local p
    for p in /proc/[0-9]*; do
        p=${p#/proc/}
        case "$p" in
            1|"$$"|"$FORWARD_PID") continue ;;
        esac
        kill -KILL "$p" 2>/dev/null
    done
}

start_server() {
    if [ "$CONSOLE_PTY" == "1" ]; then
        setsid script -q -f -e -E never -c /entrypoint.sh /dev/null <&3 &
    else
        setsid /entrypoint.sh <&3 &
    fi
    SERVER_PID=$!
}

is_stop_cmd() {
    local c
    IFS=',' read -ra cmds <<< "$STOP_COMMANDS"
    for c in "${cmds[@]}"; do
        [ "$1" == "$(trim "$c")" ] && return 0
    done
    return 1
}

forward_stdin() {
    local line
    while IFS= read -r line; do
        if is_stop_cmd "$(trim "$line")"; then
            touch "$USER_STOP_FLAG"
        fi
        printf '%s\n' "$line" >&3
    done
}

next_restart_epoch() {
    local now best="" t ts secs
    now=$(date +%s)

    if [ -n "$(trim "$RESTART_TIMES")" ]; then
        IFS=',' read -ra times <<< "$RESTART_TIMES"
        for t in "${times[@]}"; do
            t=$(trim "$t")
            [ -z "$t" ] && continue
            if ! ts=$(date -d "today $t" +%s 2>/dev/null); then
                log "Hora de reinicio inválida en RESTART_TIMES: '$t' (formato HH:MM)"
                continue
            fi
            (( ts <= now + 60 )) && ts=$(date -d "tomorrow $t" +%s)
            if [ -z "$best" ] || (( ts < best )); then best=$ts; fi
        done
        echo "$best"
        return
    fi

    secs=$(awk -v h="$RESTART_INTERVAL_HOURS" 'BEGIN { printf "%d", h * 3600 }' 2>/dev/null)
    if [ -n "$secs" ] && (( secs > 0 )); then
        echo $(( now + secs ))
    fi
}

scheduler() {
    trap '[ -n "$SLEEP_PID" ] && kill "$SLEEP_PID" 2>/dev/null; exit 0' TERM
    trap '' INT

    local target now w warnings
    target=$(next_restart_epoch)
    if [ -z "$target" ]; then
        log "Reinicio programado desactivado."
        return
    fi
    log "Próximo reinicio programado: $(date -d "@$target" '+%Y-%m-%d %H:%M:%S %Z')"

    warnings=$(tr ',' '\n' <<< "$RESTART_WARNINGS" | tr -d ' \r' | grep -E '^[0-9]+$' | sort -rn)
    for w in $warnings; do
        now=$(date +%s)
        (( target - w < now )) && continue
        zzz $(( target - w - now ))
        send_cmd "${RESTART_WARNING_CMD//%TIME%/$(fmt_time "$w")}"
    done

    now=$(date +%s)
    (( target > now )) && zzz $(( target - now ))

    touch "$SCHEDULED_FLAG"
    log "Ejecutando reinicio programado..."
    send_cmd "$RESTART_STOP_CMD"

    zzz "$STOP_TIMEOUT"
    log "El servidor no se cerró en ${STOP_TIMEOUT}s, forzando cierre."
    kill_server KILL
}

stop_scheduler() {
    if [ -n "$SCHEDULER_PID" ]; then
        kill -TERM "$SCHEDULER_PID" 2>/dev/null
        wait "$SCHEDULER_PID" 2>/dev/null
        SCHEDULER_PID=""
    fi
}

on_signal() {
    log "Señal de parada recibida, apagando servidor..."
    touch "$USER_STOP_FLAG"
    kill_server INT
    [ -n "$SLEEP_PID" ] && kill "$SLEEP_PID" 2>/dev/null
}
trap on_signal INT TERM

cd /home/container || exit 1

rm -f "$FIFO" "$USER_STOP_FLAG" "$SCHEDULED_FLAG"
mkfifo "$FIFO" || { log "No se pudo crear $FIFO"; exit 1; }
exec 3<>"$FIFO"

exec 4<&0
[ "$CONSOLE_PTY" == "1" ] && [ -t 0 ] && stty -echo 2>/dev/null
forward_stdin <&4 &
FORWARD_PID=$!

log "Crash restart: $AUTO_RESTART_ON_CRASH | Intervalo: ${RESTART_INTERVAL_HOURS}h | Horas fijas: ${RESTART_TIMES:-ninguna} | TZ: $TZ"

while true; do
    rm -f "$SCHEDULED_FLAG"

    start_server

    scheduler &
    SCHEDULER_PID=$!

    while true; do
        wait "$SERVER_PID"
        EXIT_CODE=$?
        kill -0 "$SERVER_PID" 2>/dev/null || break
    done

    stop_scheduler
    kill_server KILL
    kill_orphans
    SERVER_PID=""

    if [ -f "$USER_STOP_FLAG" ]; then
        log "Servidor detenido desde el panel."
        break
    fi

    if [ -f "$SCHEDULED_FLAG" ]; then
        log "Reinicio programado completado, levantando servidor..."
        zzz 3
        [ -f "$USER_STOP_FLAG" ] && break
        continue
    fi

    if (( EXIT_CODE == 0 )) && [ "$RESTART_ON_CLEAN_EXIT" != "1" ]; then
        log "El servidor salió normalmente (código 0)."
        break
    fi

    log "El servidor se cerró inesperadamente (código $EXIT_CODE)."
    if [ "$AUTO_RESTART_ON_CRASH" != "1" ]; then
        exit "$EXIT_CODE"
    fi

    NOW=$(date +%s)
    RECENT=()
    for t in "${CRASH_TIMES[@]}"; do
        (( NOW - t < CRASH_WINDOW )) && RECENT+=("$t")
    done
    RECENT+=("$NOW")
    CRASH_TIMES=("${RECENT[@]}")

    if (( ${#CRASH_TIMES[@]} > CRASH_MAX_RESTARTS )); then
        log "Demasiados crashes (${#CRASH_TIMES[@]} en ${CRASH_WINDOW}s). No se reinicia más, revisa la consola."
        exit "$EXIT_CODE"
    fi

    log "Reiniciando en ${CRASH_RESTART_DELAY}s (crash ${#CRASH_TIMES[@]}/${CRASH_MAX_RESTARTS})..."
    zzz "$CRASH_RESTART_DELAY"
    [ -f "$USER_STOP_FLAG" ] && break
done

kill "$FORWARD_PID" 2>/dev/null
exit 0
