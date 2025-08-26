#!/usr/bin/env bash
# Ejemplos de uso
# Revisar 50 (por defecto), con salida detallada:  ./clean_domains.sh --verbose
# Revisar 100: ./clean_domains.sh --batch 100
# Probar SIN modificar nada (ver qué pasaría): ./clean_domains.sh --batch 200 --dry-run --verbose
# Usar archivos personalizados: ./clean_domains.sh --file /ruta/domains.lst --log /ruta/clean.log --batch 75

set -euo pipefail

# Defaults
DOMAINS_FILE="domains.lst"
LOG_FILE="clean.log"
BATCH_SIZE=50
DRY_RUN=0
VERBOSE=0

usage() {
  cat <<EOF
Uso: $0 [opciones]
  --batch N        Número máximo de dominios a revisar en esta ejecución (por defecto: $BATCH_SIZE)
  --file PATH      Archivo de dominios (por defecto: $DOMAINS_FILE)
  --log PATH       Archivo de log (por defecto: $LOG_FILE)
  --dry-run        No modifica domains.lst; solo reporta qué pasaría
  --verbose        Muestra detalles durante la ejecución
  -h, --help       Esta ayuda

Ejemplos:
  $0 --batch 100 --verbose
  $0 --file /ruta/domains.lst --log /ruta/clean.log --dry-run
EOF
}

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --batch)
      BATCH_SIZE="${2:-}"; shift 2;;
    --file)
      DOMAINS_FILE="${2:-}"; shift 2;;
    --log)
      LOG_FILE="${2:-}"; shift 2;;
    --dry-run)
      DRY_RUN=1; shift;;
    --verbose)
      VERBOSE=1; shift;;
    -h|--help)
      usage; exit 0;;
    *)
      echo "Opción desconocida: $1"; usage; exit 1;;
  esac
done

# Ir al dir del script para rutas relativas
thisScript="$(realpath "$0")"
workDir="${thisScript%/*}"
cd "$workDir"

# Dependencias mínimas (host o dig)
HAS_HOST=0; HAS_DIG=0
if command -v host >/dev/null 2>&1; then HAS_HOST=1; fi
if command -v dig  >/dev/null 2>&1; then HAS_DIG=1;  fi
if [[ $HAS_HOST -eq 0 && $HAS_DIG -eq 0 ]]; then
  echo "Faltan utilidades DNS. Instala 'bind9-dnsutils' (host) o 'dnsutils' (dig)."
  echo "Ej.: sudo apt update && sudo apt install -y bind9-dnsutils dnsutils"
  exit 1
fi

# Validaciones
if [[ ! -f "$DOMAINS_FILE" ]]; then
  echo "No existe $DOMAINS_FILE"; exit 1
fi
if [[ ! -s "$DOMAINS_FILE" ]]; then
  echo "$DOMAINS_FILE está vacío"; exit 0
fi
if ! [[ "$BATCH_SIZE" =~ ^[0-9]+$ ]] || [[ "$BATCH_SIZE" -le 0 ]]; then
  echo "--batch debe ser entero > 0"; exit 1
fi

# Función: ¿tiene AAAA?
has_aaaa() {
  # $1 = dominio
  local d="$1" out=""
  if [[ $HAS_HOST -eq 1 ]]; then
    # host -t AAAA devuelve líneas con "has IPv6 address"
    # limitar tiempo con timeout si está disponible
    if command -v timeout >/dev/null 2>&1; then
      out="$(timeout 3 host -t AAAA "$d" 2>/dev/null || true)"
    else
      out="$(host -t AAAA "$d" 2>/dev/null || true)"
    fi
    grep -q "has IPv6 address" <<<"$out" && return 0
    # si host no encontró, caemos a dig por si acaso
  fi
  if [[ $HAS_DIG -eq 1 ]]; then
    if command -v timeout >/dev/null 2>&1; then
      out="$(timeout 3 dig +time=2 +tries=1 -t AAAA +short "$d" 2>/dev/null | tail -n 1 || true)"
    else
      out="$(dig +time=2 +tries=1 -t AAAA +short "$d" 2>/dev/null | tail -n 1 || true)"
    fi
    [[ -n "$out" ]] && return 0
  fi
  return 1
}

# Limpieza de líneas: quitamos espacios y comentarios
TMP_NORM="$(mktemp)"; trap 'rm -f "$TMP_NORM"' EXIT
awk '
  { sub(/^[ \t\r]+/, "", $0); sub(/[ \t\r]+$/, "", $0); }
  $0 != "" && $0 !~ /^#/ { print $0 }
' "$DOMAINS_FILE" > "$TMP_NORM"

TOTAL=$(wc -l < "$TMP_NORM")
[[ $TOTAL -eq 0 ]] && { echo "No hay dominios válidos en $DOMAINS_FILE"; exit 0; }

# Selección del lote (primeros N)
TMP_CHECK="$(mktemp)"; TMP_REST="$(mktemp)"
trap 'rm -f "$TMP_CHECK" "$TMP_REST"' EXIT
head -n "$BATCH_SIZE" "$TMP_NORM" > "$TMP_CHECK"
tail -n +$((BATCH_SIZE+1)) "$TMP_NORM" > "$TMP_REST" || true

# Respaldo solo si NO es dry-run
ts="$(date +'%Y%m%d-%H%M%S')"
if [[ $DRY_RUN -eq 0 ]]; then
  cp -f "$DOMAINS_FILE" "${DOMAINS_FILE}.bak.$ts"
fi

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
touch "$LOG_FILE"

kept=0; deleted=0
TMP_KEEP_HEAD="$(mktemp)"; trap 'rm -f "$TMP_KEEP_HEAD"' EXIT

while IFS= read -r domain; do
  [[ -z "$domain" ]] && continue
  [[ $VERBOSE -eq 1 ]] && echo "Revisando: $domain ..."
  if has_aaaa "$domain"; then
    echo "$domain" >> "$TMP_KEEP_HEAD"
    kept=$((kept+1))
    [[ $VERBOSE -eq 1 ]] && echo "  -> tiene AAAA (se conserva)"
  else
    deleted=$((deleted+1))
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "DRY-RUN: [$domain] sin AAAA (no hay IPV6) -> sería eliminado de la lista"
    else
      printf "[%s] %s sin AAAA (no hay IPV6) -> eliminado de la lista\n" \
        "$(date '+%F %T')" "$domain" >> "$LOG_FILE"
      [[ $VERBOSE -eq 1 ]] && echo "  -> sin AAAA (eliminado)"
    fi
  fi
done < "$TMP_CHECK"

if [[ $DRY_RUN -eq 1 ]]; then
  echo "----- DRY-RUN RESUMEN -----"
  echo "Revisados: $(wc -l < "$TMP_CHECK")  | Con AAAA: $kept  | Sin AAAA: $deleted"
  echo "NO se modificó $DOMAINS_FILE"
  exit 0
fi

# Reconstruir domains.lst: (conservados del head) + (resto intacto)
TMP_NEW="$(mktemp)"; trap 'rm -f "$TMP_NEW"' EXIT
cat "$TMP_KEEP_HEAD" > "$TMP_NEW"
cat "$TMP_REST"     >> "$TMP_NEW"
mv -f "$TMP_NEW" "$DOMAINS_FILE"

echo "Limpieza terminada: conservados=$kept, eliminados=$deleted, revisados=$(wc -l < "$TMP_CHECK"), total_original=$TOTAL"
echo "Respaldo: ${DOMAINS_FILE}.bak.$ts"
echo "Log de eliminados: $LOG_FILE"
