# henet
HE.net ipv6 Certificacion Script

Es un script antiguo pero si aun no completaste tus pruebas hasta los 1500 puntos, con esto puedes hacerlo, solo necesitas un servidor linux con ipv6.

# dependencias requeridas:

apt update
apt install -y curl traceroute iputils-ping dnsutils whois html2text coreutils cron


# henet.sh // script para completar las pruebas diarias de la certificacion

HE.net IPv6 Certification — ejecución única para cron
- Un solo archivo maestro de dominios: domains.lst (uno por línea)
- Si un dominio no tiene AAAA, se elimina de domains.lst
- Sin bucles infinitos ni sleep; programar por cron
- Mantiene archivos: <test>-pass y <test>-fail
- Si HE responde "Sorry, you've already submitted an IPv6...", se pasa a la siguiente prueba sin reintentos

# clean.sh  // para eliminar dominios que no tienen ipv6

 Ejemplos de uso
 Revisar 50 (por defecto), con salida detallada:  ./clean_domains.sh --verbose
 Revisar 100: ./clean_domains.sh --batch 100
 Probar SIN modificar nada (ver qué pasaría): ./clean_domains.sh --batch 200 --dry-run --verbose
 Usar archivos personalizados: ./clean_domains.sh --file /ruta/domains.lst --log /ruta/clean.log --batch 75


# Como poner el crontab -e

0 15 * * * /root/henet/henet.sh

Saludos!

Alex
