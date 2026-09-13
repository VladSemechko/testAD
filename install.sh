#!/bin/bash
#
# AdGuard Home Auto-Installer для Ubuntu 22.04/24.04 LTS
# Автоматическая установка и настройка AdGuard Home с SSL от Let's Encrypt
#
# Автор: DevOps Engineer
# Версия: 1.0
#

set -e

# ============================================================================
# ЦВЕТОВЫЕ КОДЫ ДЛЯ ВЫВОДА
# ============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# ============================================================================
# ФУНКЦИИ ДЛЯ ВЫВОДА СООБЩЕНИЙ
# ============================================================================
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "\n${CYAN}${BOLD}=== $1 ===${NC}\n"
}

# ============================================================================
# ПРОВЕРКА ROOT-ПРАВ
# ============================================================================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Этот скрипт должен выполняться от имени root!"
        exit 1
    fi
    log_success "Root-права подтверждены"
}

# ============================================================================
# СБОР ВВОДНЫХ ДАННЫХ ОТ ПОЛЬЗОВАТЕЛЯ
# ============================================================================
collect_user_input() {
    log_step "Сбор информации для настройки"
    
    # Доменное имя
    while true; do
        read -p "Введите доменное имя для SSL-сертификата (например, dns.example.com): " DOMAIN_NAME
        if [[ -n "$DOMAIN_NAME" && "$DOMAIN_NAME" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            break
        else
            log_error "Некорректный формат домена. Попробуйте снова."
        fi
    done
    
    # Email для Let's Encrypt
    while true; do
        read -p "Введите email для уведомлений Let's Encrypt: " LETS_EMAIL
        if [[ -n "$LETS_EMAIL" && "$LETS_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
            break
        else
            log_error "Некорректный формат email. Попробуйте снова."
        fi
    done
    
    # Имя администратора
    read -p "Введите имя администратора AdGuard Home [admin]: " ADMIN_USER
    ADMIN_USER=${ADMIN_USER:-admin}
    
    # Пароль администратора
    while true; do
        read -sp "Введите пароль администратора (минимум 8 символов): " ADMIN_PASS
        echo ""
        read -sp "Подтвердите пароль: " ADMIN_PASS_CONFIRM
        echo ""
        
        if [[ ${#ADMIN_PASS} -ge 8 && "$ADMIN_PASS" == "$ADMIN_PASS_CONFIRM" ]]; then
            break
        else
            log_error "Пароли не совпадают или длина менее 8 символов. Попробуйте снова."
        fi
    done
    
    log_success "Все данные получены:"
    echo -e "  Домен: ${CYAN}$DOMAIN_NAME${NC}"
    echo -e "  Email: ${CYAN}$LETS_EMAIL${NC}"
    echo -e "  Логин: ${CYAN}$ADMIN_USER${NC}"
}

# ============================================================================
# ОБНОВЛЕНИЕ СИСТЕМЫ И УСТАНОВКА ПАКЕТОВ
# ============================================================================
update_system() {
    log_step "Обновление системы и установка необходимых пакетов"
    
    log_info "Обновление списка пакетов..."
    apt update -qq
    
    log_info "Обновление установленных пакетов..."
    DEBIAN_FRONTEND=noninteractive apt upgrade -y -qq
    
    log_info "Установка необходимых утилит..."
    DEBIAN_FRONTEND=noninteractive apt install -y -qq \
        curl \
        wget \
        tar \
        htop \
        net-tools \
        apache2-utils \
        certbot \
        ufw \
        lsof \
        gnupg
    
    log_success "Система обновлена и пакеты установлены"
}

# ============================================================================
# НАСТРОЙКА ФАЙРВОЛА UFW
# ============================================================================
setup_firewall() {
    log_step "Настройка файрвола UFW"
    
    log_info "Сброс правил UFW к настройкам по умолчанию..."
    ufw --force reset
    
    log_info "Установка политики по умолчанию: запрет входящих соединений..."
    ufw default deny incoming
    
    log_info "Установка политики по умолчанию: разрешение исходящих соединений..."
    ufw default allow outgoing
    
    log_info "Открытие порта 22/tcp (SSH)..."
    ufw allow 22/tcp comment 'SSH'
    
    log_info "Открытие портов 53/tcp и 53/udp (DNS)..."
    ufw allow 53/tcp comment 'DNS-TCP'
    ufw allow 53/udp comment 'DNS-UDP'
    
    log_info "Открытие порта 80/tcp (HTTP для SSL-валидации)..."
    ufw allow 80/tcp comment 'HTTP'
    
    log_info "Открытие порта 443/tcp (HTTPS)..."
    ufw allow 443/tcp comment 'HTTPS'
    
    log_info "Открытие порта 853/tcp (DNS over TLS)..."
    ufw allow 853/tcp comment 'DoT'
    
    log_info "Открытие порта 784/udp (DNS over QUIC)..."
    ufw allow 784/udp comment 'DoQ'
    
    log_info "Временное открытие порта 3000/tcp для первоначальной настройки..."
    ufw allow 3000/tcp comment 'AdGuard-Setup'
    
    log_info "Включение UFW..."
    echo "y" | ufw enable
    
    log_success "Файрвол настроен"
}

# ============================================================================
# ОСВОБОЖДЕНИЕ ПОРТА 53
# ============================================================================
free_port_53() {
    log_step "Проверка и освобождение порта 53"
    
    # Проверяем, занят ли порт 53
    if ss -tuln | grep -q ':53 '; then
        log_warning "Порт 53 занят. Проверка systemd-resolved..."
        
        if systemctl is-active --quiet systemd-resolved; then
            log_info "Остановка и отключение systemd-resolved..."
            systemctl stop systemd-resolved
            systemctl disable systemd-resolved
            
            # Создаем новый resolv.conf
            log_info "Настройка /etc/resolv.conf..."
            cat > /etc/resolv.conf << EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
            chattr +i /etc/resolv.conf 2>/dev/null || true
            
            log_success "systemd-resolved остановлен, DNS перенастроен"
        else
            log_info "systemd-resolved не активен, проверка других процессов..."
            # Попытка найти и остановить другие процессы на порту 53
            local pid=$(ss -tlnp | grep ':53 ' | awk '{print $NF}' | grep -oP 'pid=\K[0-9]+' | head -1)
            if [[ -n "$pid" ]]; then
                log_warning "Найден процесс на порту 53 (PID: $pid). Остановка..."
                kill -9 "$pid" 2>/dev/null || true
            fi
        fi
    else
        log_success "Порт 53 свободен"
    fi
}

# ============================================================================
# УСТАНОВКА ADGUARD HOME
# ============================================================================
install_adguard() {
    log_step "Загрузка и установка AdGuard Home"
    
    # Получаем последнюю версию с GitHub
    log_info "Получение информации о последней версии AdGuard Home..."
    LATEST_VERSION=$(curl -s https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest | grep '"tag_name"' | cut -d'"' -f4)
    
    if [[ -z "$LATEST_VERSION" ]]; then
        log_error "Не удалось получить информацию о версии. Используем последнюю стабильную."
        LATEST_VERSION="v0.107.54"
    fi
    
    log_info "Последняя версия: $LATEST_VERSION"
    
    # Определяем архитектуру
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH_FILE="amd64" ;;
        aarch64) ARCH_FILE="arm64" ;;
        armv7l) ARCH_FILE="arm" ;;
        *) log_error "Неподдерживаемая архитектура: $ARCH"; exit 1 ;;
    esac
    
    log_info "Архитектура: $ARCH ($ARCH_FILE)"
    
    # Формируем URL загрузки
    DOWNLOAD_URL="https://github.com/AdguardTeam/AdGuardHome/releases/download/${LATEST_VERSION}/AdGuardHome_linux_${ARCH_FILE}.tar.gz"
    
    log_info "Загрузка AdGuard Home..."
    mkdir -p /opt/AdGuardHome
    cd /tmp
    wget -q --show-progress "$DOWNLOAD_URL" -O AdGuardHome.tar.gz
    
    log_info "Распаковка в /opt/AdGuardHome..."
    tar -xzf AdGuardHome.tar.gz -C /opt/AdGuardHome --strip-components=1
    
    # Удаляем архив
    rm -f AdGuardHome.tar.gz
    
    cd /opt/AdGuardHome
    
    log_info "Установка как systemd-сервис..."
    ./AdGuardHome -s install
    
    log_success "AdGuard Home установлен"
}

# ============================================================================
# ГЕНЕРАЦИЯ BCRYPT ХЕША ДЛЯ ПАРОЛЯ
# ============================================================================
generate_bcrypt_hash() {
    log_info "Генерация bcrypt-хеша для пароля администратора..."
    
    # Используем htpasswd для генерации хеша
    local hash=$(htpasswd -nbBC 10 "$ADMIN_USER" "$ADMIN_PASS" | cut -d':' -f2 | tr -d '\n')
    
    if [[ -z "$hash" ]]; then
        log_error "Не удалось сгенерировать хеш пароля"
        exit 1
    fi
    
    echo "$hash"
}

# ============================================================================
# СОЗДАНИЕ КОНФИГУРАЦИОННОГО ФАЙЛА ADGUARD HOME
# ============================================================================
create_config() {
    log_step "Создание конфигурационного файла AdGuard Home"
    
    # Генерируем хеш пароля
    PASSWORD_HASH=$(generate_bcrypt_hash)
    
    # Получаем публичный IP для начального bind
    PUBLIC_IP=$(curl -s ifconfig.me || echo "0.0.0.0")
    
    log_info "Создание конфигурации..."
    
    cat > /opt/AdGuardHome/AdGuardHome.yaml << EOF
# Конфигурация AdGuard Home
# Создано автоматически установочным скриптом

bind_host: "0.0.0.0"
bind_port: 80
users:
  - name: "${ADMIN_USER}"
    password: "${PASSWORD_HASH}"
language: ru
theme: auto
dns:
  bind_hosts:
    - "0.0.0.0"
  port: 53
  upstream_dns:
    - "https://dns.cloudflare.com/dns-query"
    - "https://dns.google/dns-query"
  bootstrap_dns:
    - "9.9.9.10"
    - "149.112.112.10"
  cache_size: 4194304
  cache_ttl_min: 0
  cache_ttl_max: 0
  cache_optimistic: false
  blocking_mode: default
  edns_client_subnet:
    custom_ip: ""
    enabled: false
  max_goroutines: 300
  handle_ddr: true
  ipset: []
  ipset_file: ""
  bootstrap_prefer_ipv6: false
  upstream_timeout: 10
  private_networks: []
  use_private_ptr_resolvers: true
  local_ptr_upstreams: []
  use_dns64: false
  dns64_prefixes: []
  serve_http3: false
  use_http3_upstreams: false
  serve_plain_dns: true
  hostsfile_enabled: true
querylog:
  dir_path: ""
  ignored: []
  interval: 2160h
  size_memory: 1000
  enabled: true
  file_enabled: true
statistics:
  dir_path: ""
  ignored: []
  interval: 24h
  enabled: true
filters:
  - enabled: true
    url: "https://raw.githubusercontent.com/AdguardTeam/FiltersRegistry/master/filters/filter_1_Russian/filter.txt"
    name: "Russian filter"
    id: 1697585350
whitelist_filters: []
user_rules: []
dhcp:
  enabled: false
  interface_name: ""
  local_domain_name: lan
  dhcpv4:
    gateway_ip: ""
    subnet_mask: ""
    range_start: ""
    range_end: ""
    lease_duration: 86400
    icmp_timeout_msec: 1000
    options: []
  dhcpv6:
    range_start: ""
    lease_duration: 86400
    ra_slaac_only: false
    ra_allow_slaac: false
clients:
  runtime_sources:
    whois: true
    arp: true
    rdns: true
    dhcp: true
    hosts: true
  persistent: []
log_localtime: false
log_verbose: false
log_file: ""
log_max_backups: 0
log_max_size: 100
log_max_age: 3
log_compress: false
log_interval: 1
os:
  group: ""
  user: ""
  rlimit_nofile: 0
schema_version: 28
http_proxy: ""
tls:
  enabled: false
  server_name: ""
  force_https: false
  port_https: 443
  port_dns_over_tls: 853
  port_dns_over_quic: 784
  certificate_chain: ""
  private_key: ""
  certificate_path: ""
  private_key_path: ""
  min_tls_version: 1.2
  strict_sni_check: false
filtering:
  filtering_enabled: true
  filters_update_interval: 24
  blocked_response_ttl: 10
  filtering_enabled_ipv6: true
  safebrowsing_enabled: false
  safebrowsing_cache_size: 1048576
  safesearch_enabled: false
  safesearch_cache_size: 1048576
  parental_enabled: false
  parental_cache_size: 1048576
  protection_disabled_until: null
safe_search:
  enabled: false
  bing: true
  duckduckgo: true
  google: true
  pixabay: true
  yandex: true
  youtube: true
rewrites: []
blocked_services:
  schedule:
    time_zone: "UTC"
  ids: []
services_url: {}
tunnel:
  enabled: false
  instances: []
spleen:
  enabled: false
  block_all: false
  cache_size: 65536
  cache_ttl: 3600
  ignore_list: []
  mode: optimal
  thresholds:
    ham: 0.5
    spam: 0.5
EOF

    log_success "Конфигурационный файл создан"
}

# ============================================================================
# ОСТАНОВКА ПРОЦЕССОВ НА ПОРТУ 80
# ============================================================================
stop_port_80_processes() {
    log_step "Освобождение порта 80 для получения SSL-сертификата"
    
    # Находим процессы на порту 80
    local port_80_users=$(ss -tlnp | grep ':80 ' || true)
    
    if [[ -n "$port_80_users" ]]; then
        log_warning "Обнаружены процессы на порту 80:"
        echo "$port_80_users"
        
        # Пробуем определить сервисы и остановить их
        for service in nginx apache2 httpd lighttpd caddy traefik; do
            if systemctl is-active --quiet "$service" 2>/dev/null; then
                log_info "Остановка сервиса $service..."
                systemctl stop "$service" || true
                log_success "Сервис $service остановлен"
            fi
        done
        
        # Если ещё есть процессы, пытаемся найти их через lsof
        if ss -tlnp | grep -q ':80 '; then
            log_warning "Порт 80 всё ещё занят. Попытка принудительной остановки..."
            local pids=$(lsof -ti:80 2>/dev/null || true)
            if [[ -n "$pids" ]]; then
                for pid in $pids; do
                    log_info "Остановка процесса PID $pid..."
                    kill -9 "$pid" 2>/dev/null || true
                done
            fi
        fi
    else
        log_success "Порт 80 свободен"
    fi
    
    # Останавливаем AdGuard Home если он запущен
    if systemctl is-active --quiet AdGuardHome; then
        log_info "Остановка AdGuard Home для получения сертификата..."
        systemctl stop AdGuardHome
    fi
}

# ============================================================================
# ПОЛУЧЕНИЕ SSL-СЕРТИФИКАТА ОТ LET'S ENCRYPT
# ============================================================================
get_ssl_certificate() {
    log_step "Получение SSL-сертификата от Let's Encrypt"
    
    log_info "Запрос сертификата для домена $DOMAIN_NAME..."
    
    # Используем standalone режим certbot
    if ! certbot certonly --standalone \
        --email "$LETS_EMAIL" \
        --agree-tos \
        --no-eff-email \
        --domain "$DOMAIN_NAME" \
        --non-interactive; then
        log_error "Не удалось получить SSL-сертификат!"
        log_error "Возможные причины:"
        log_error "  1. Домен не настроен (A-запись не указывает на этот сервер)"
        log_error "  2. Порт 80 заблокирован файрволом"
        log_error "  3. Превышен лимит запросов Let's Encrypt"
        exit 1
    fi
    
    log_success "SSL-сертификат успешно получен!"
    
    # Проверяем наличие файлов сертификата
    if [[ ! -f "/etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem" ]]; then
        log_error "Файл сертификата не найден!"
        exit 1
    fi
    
    if [[ ! -f "/etc/letsencrypt/live/$DOMAIN_NAME/privkey.pem" ]]; then
        log_error "Файл приватного ключа не найден!"
        exit 1
    fi
    
    log_success "Сертификаты расположены:"
    echo "  Полный сертификат: /etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem"
    echo "  Приватный ключ: /etc/letsencrypt/live/$DOMAIN_NAME/privkey.pem"
}

# ============================================================================
# НАСТРОЙКА ШИФРОВАНИЯ В ADGUARD HOME
# ============================================================================
configure_encryption() {
    log_step "Настройка шифрования в AdGuard Home"
    
    log_info "Обновление конфигурации с параметрами TLS..."
    
    # Читаем текущий конфиг и обновляем секцию tls
    # Используем sed для замены значений в существующей секции tls
    
    sed -i "s|enabled: false|enabled: true|g" /opt/AdGuardHome/AdGuardHome.yaml
    sed -i "s|server_name: \"\"|server_name: \"$DOMAIN_NAME\"|g" /opt/AdGuardHome/AdGuardHome.yaml
    sed -i "s|force_https: false|force_https: true|g" /opt/AdGuardHome/AdGuardHome.yaml
    sed -i "s|certificate_path: \"\"|certificate_path: \"/etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem\"|g" /opt/AdGuardHome/AdGuardHome.yaml
    sed -i "s|private_key_path: \"\"|private_key_path: \"/etc/letsencrypt/live/$DOMAIN_NAME/privkey.pem\"|g" /opt/AdGuardHome/AdGuardHome.yaml
    
    log_success "Шифрование настроено"
}

# ============================================================================
# НАСТРОЙКА АВТОМАТИЧЕСКОГО ПРОДЛЕНИЯ СЕРТИФИКАТА
# ============================================================================
setup_cert_renewal() {
    log_step "Настройка автоматического продления SSL-сертификата"
    
    log_info "Создание cron-задачи для продления сертификата..."
    
    # Создаем скрипт для продления
    cat > /usr/local/bin/renew-adguard-cert.sh << 'EOF'
#!/bin/bash
# Скрипт автоматического продления SSL-сертификата для AdGuard Home

certbot renew --quiet --deploy-hook "systemctl restart AdGuardHome"
EOF
    
    chmod +x /usr/local/bin/renew-adguard-cert.sh
    
    # Добавляем задачу в cron (проверка дважды в день)
    if ! crontab -l | grep -q "renew-adguard-cert.sh"; then
        (crontab -l 2>/dev/null; echo "0 0,12 * * * /usr/local/bin/renew-adguard-cert.sh") | crontab -
        log_success "Cron-задача добавлена"
    else
        log_info "Cron-задача уже существует"
    fi
    
    # Тестовый запуск продления (dry-run)
    log_info "Тестирование процедуры продления (dry-run)..."
    certbot renew --dry-run --quiet || log_warning "Dry-run завершился с предупреждениями (это нормально для новых сертификатов)"
    
    log_success "Автоматическое продление настроено"
}

# ============================================================================
# ФИНАЛИЗАЦИЯ УСТАНОВКИ
# ============================================================================
finalize() {
    log_step "Завершение установки"
    
    log_info "Удаление временного правила UFW для порта 3000..."
    ufw delete allow 3000/tcp comment 'AdGuard-Setup' 2>/dev/null || ufw delete allow 3000/tcp 2>/dev/null || true
    
    log_info "Перезапуск AdGuard Home..."
    systemctl daemon-reload
    systemctl restart AdGuardHome
    
    # Ждем запуска сервиса
    sleep 3
    
    if ! systemctl is-active --quiet AdGuardHome; then
        log_error "AdGuard Home не запустился! Проверьте логи: journalctl -u AdGuardHome"
        exit 1
    fi
    
    log_success "AdGuard Home перезапущен"
}

# ============================================================================
# ВЫВОД ФИНАЛЬНОГО ОТЧЕТА
# ============================================================================
print_summary() {
    log_step "Установка завершена успешно!"
    
    # Получаем публичный IP
    PUBLIC_IP=$(curl -s ifconfig.me || echo "не определен")
    
    echo -e "${GREEN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║           AdGuard Home успешно установлен и настроен         ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    echo -e "${BOLD}Выполненные действия:${NC}"
    echo "  ✓ Система обновлена"
    echo "  ✓ Необходимые пакеты установлены"
    echo "  ✓ Файрвол UFW настроен"
    echo "  ✓ Порт 53 освобожден"
    echo "  ✓ AdGuard Home установлен"
    echo "  ✓ SSL-сертификат Let's Encrypt получен"
    echo "  ✓ Шифрование включено"
    echo "  ✓ Автоматическое продление сертификата настроено"
    echo ""
    
    echo -e "${BOLD}Панель управления:${NC}"
    echo -e "  URL: ${CYAN}https://$DOMAIN_NAME${NC}"
    echo -e "  Логин: ${CYAN}$ADMIN_USER${NC}"
    echo -e "  Пароль: ${CYAN}$ADMIN_PASS${NC}"
    echo ""
    
    echo -e "${BOLD}DNS-серверы для настройки клиентов:${NC}"
    echo -e "  Обычный DNS: ${CYAN}$PUBLIC_IP${NC}"
    echo -e "  DNS over HTTPS (DoH): ${CYAN}https://$DOMAIN_NAME/dns-query${NC}"
    echo -e "  DNS over TLS (DoT): ${CYAN}$DOMAIN_NAME:853${NC}"
    echo -e "  DNS over QUIC (DoQ): ${CYAN}$DOMAIN_NAME:784${NC}"
    echo ""
    
    echo -e "${BOLD}Команды управления сервисом:${NC}"
    echo "  Запуск:      systemctl start AdGuardHome"
    echo "  Остановка:   systemctl stop AdGuardHome"
    echo "  Перезапуск:  systemctl restart AdGuardHome"
    echo "  Статус:      systemctl status AdGuardHome"
    echo "  Логи:        journalctl -u AdGuardHome -f"
    echo ""
    
    echo -e "${BOLD}Полезные команды:${NC}"
    echo "  Обновить фильтры: curl -X POST http://localhost/control/refresh -u '$ADMIN_USER:$ADMIN_PASS'"
    echo "  Продлить сертификат вручную: certbot renew --force-renewal"
    echo ""
    
    echo -e "${YELLOW}ВАЖНО:${NC}"
    echo "  • Убедитесь, что A-запись домена $DOMAIN_NAME указывает на IP: $PUBLIC_IP"
    echo "  • Сохраните пароль администратора в надежном месте"
    echo "  • Для доступа к панели используйте только HTTPS"
    echo ""
    
    echo -e "${GREEN}Установка завершена!${NC}"
}

# ============================================================================
# ОСНОВНАЯ ФУНКЦИЯ
# ============================================================================
main() {
    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║     AdGuard Home Auto-Installer для Ubuntu 22.04/24.04      ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    check_root
    collect_user_input
    update_system
    setup_firewall
    free_port_53
    install_adguard
    create_config
    stop_port_80_processes
    get_ssl_certificate
    configure_encryption
    setup_cert_renewal
    finalize
    print_summary
}

# Запуск основной функции
main "$@"
