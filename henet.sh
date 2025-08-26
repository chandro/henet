#!/bin/bash
# HE.net IPv6 Certification — ejecución única para cron
# - Un solo archivo maestro de dominios: domains.lst (uno por línea)
# - Si un dominio no tiene AAAA, se elimina de domains.lst
# - Sin bucles infinitos ni sleep; programar por cron
# - Mantiene archivos: <test>-pass y <test>-fail
# - Si HE responde "Sorry, you've already submitted an IPv6...", se pasa a la siguiente prueba sin reintentos
# - debes tener instalado los programas y dependencias:  apt install -y curl traceroute iputils-ping dnsutils whois html2text coreutils cron

USERNAME="dedicados"
PASSWORD="pantufla!!"
maxTries=5
DOMAINS_FILE="domains.lst"

thisScript="$(realpath "$0")"
workDir="${thisScript%/*}"
cd "$workDir" || { echo "No pude entrar a $workDir"; exit 1; }

# Log: append para cron
exec >> ./henet.log 2>&1

# Limpieza de temporales al salir
trap 'rm -f output cookies' EXIT

remove_domain() {
  local d="$1"
  [ -f "$DOMAINS_FILE" ] || return 0
  grep -F -x -v "$d" "$DOMAINS_FILE" > "$DOMAINS_FILE.tmp" && mv "$DOMAINS_FILE.tmp" "$DOMAINS_FILE"
}

random_domain() {
  [ -s "$DOMAINS_FILE" ] || { echo ""; return; }
  local total num
  total=$(wc -l < "$DOMAINS_FILE")
  num=$(( RANDOM % total + 1 ))
  sed -n "${num}p" "$DOMAINS_FILE"
}

pick_domain_with_aaaa() {
  local tries=0 max=200 d aaaa
  while :; do
    [ -s "$DOMAINS_FILE" ] || { echo "No quedan dominios en $DOMAINS_FILE"; return 1; }
    d="$(random_domain)"
    [ -n "$d" ] || { echo "No pude obtener dominio aleatorio"; return 1; }
    aaaa="$(dig -t AAAA +short "$d" | tail -n 1)"
    if [ -n "$aaaa" ]; then
      DOMAIN="$d"
      IPV6="$aaaa"
      return 0
    else
      echo "$d sin AAAA (no hay IPV6) -> eliminado de domains.lst"
      echo "$d sin-AAAA" >> whois-fail
      remove_domain "$d"
    fi
    tries=$((tries+1))
    [ $tries -ge $max ] && { echo "No se encontró dominio con AAAA tras $max intentos."; return 1; }
  done
}

runTest() {
  local testType="$1"
  local count=0 code=0 submitPage="" CURLRESULT=""

  # Para todas las pruebas requerimos AAAA (traceroute6, ping6, digptr, whois y también digaaaa)
  while :; do
    count=$((count+1))
    pick_domain_with_aaaa || { echo "Saliendo de $testType: no hay dominios con AAAA en $DOMAINS_FILE"; return; }

    echo "Probando $testType con $DOMAIN (IPv6: $IPV6)"

    case "$testType" in
      traceroute6)
        $TRACERT -w 1 -m 30 "$DOMAIN" > output 2>&1
        code=$?
        submitPage="traceroute"
        ;;
      digaaaa)
        dig aaaa "$DOMAIN" > output 2>&1
        code=$?
        submitPage="aaaa"
        ;;
      digptr)
        dig -x "$IPV6" > output 2>&1
        code=$?
        submitPage="ptr"
        ;;
      ping6)
        ping6 -c 4 -n "$DOMAIN" > output 2>&1
        code=$?
        submitPage="ping"
        ;;
      whois)
        whois "$IPV6" > output 2>&1
        code=$?
        submitPage="whois"
        ;;
      *)
        echo "Tipo de prueba desconocido: $testType"
        return
        ;;
    esac

    if [ $code -ne 0 ]; then
      echo "$DOMAIN $count comando-fallo(code=$code)" >> "${testType}-fail"
      [ $count -ge $maxTries ] && { echo "ERROR: ${maxTries} ${testType} tries, bailing out"; return; }
      continue
    fi

    CURLRESULT=$(
      curl -q -s -b cookies --data-urlencode input@output \
        "https://ipv6.he.net/certification/daily.php?test=${submitPage}" \
      | html2text -width 82 \
      | grep -E -e "Sorry" -e "Result" -e "within the last 24 hours"
    )

    rm -f output
    echo "Respuesta: $CURLRESULT"

    # Caso 1: PASS explícito
    if [ "X$CURLRESULT" != "X${CURLRESULT%Result: Pass}" ]; then
      echo "$DOMAIN" >> "${testType}-pass"
      return
    fi

    # Caso 2: Ya enviado hoy (dos formas comunes de respuesta)
    if echo "$CURLRESULT" | grep -q "within the last 24 hours"; then
      # Ya se hizo en las últimas 24h -> pasar a la siguiente prueba sin reintentar
      return
    fi
    if echo "$CURLRESULT" | grep -q "Sorry, you've already submitted an IPv6"; then
      # Mensaje explícito de HE para envíos repetidos -> pasar a la siguiente prueba sin reintentar
      return
    fi

    # Caso 3: otro “Sorry” o fallo -> registrar y reintentar hasta maxTries
    echo "$DOMAIN $count $CURLRESULT" >> "${testType}-fail"
    [ $count -ge $maxTries ] && { echo "ERROR: ${maxTries} ${testType} tries, bailing out"; return; }
  done
}

######################################### MAIN ########################################

date

# Chequeo de dependencias
for i in command curl ping6 dig whois html2text; do
  command -v "$i" >/dev/null 2>&1 || { echo "Falta $i. Instálalo."; exit 1; }
done

if command -v traceroute >/dev/null 2>&1; then
  TRACERT="traceroute -6"
elif command -v traceroute6 >/dev/null 2>&1; then
  TRACERT="traceroute6"
else
  echo "Falta traceroute/traceroute6."
  exit 1
fi

[ -s "$DOMAINS_FILE" ] || { echo "Necesitas $DOMAINS_FILE con dominios (uno por línea)."; exit 1; }

echo "Iniciando login..."
curl -s -c cookies -d "f_user=$USERNAME&f_pass=$PASSWORD" "https://ipv6.he.net/certification/login.php" >/dev/null 2>&1
curl -s -b cookies "https://ipv6.he.net/certification/cert-main.php" | html2text | grep "Name:" >/dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "Login Failed. Verifica USERNAME/PASSWORD."
  exit 1
fi
echo "Login OK."

# Ejecutar una vez cada prueba
runTest traceroute6
runTest digaaaa
runTest digptr
runTest ping6
runTest whois

echo "Ejecución terminada."
