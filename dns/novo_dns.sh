#!/bin/bash

# CONFIGURAÇÃO DO SERVIDOR DNS (BIND)

# ==============================================================================
# VARIÁVEIS DE CONFIGURAÇÃO (AJUSTE ESTES VALORES SE NECESSÁRIO)
# ==============================================================================
# IP do Servidor DNS/DHCP - Assumindo que o DNS está na máquina Kea/DNS
IP="192.168.10.1"              #IP ESTATICO DO SERVIDOR DNS
HOSTNAME_SERVER="servidor1"     #Nome de Host do Servidor DNS
DOMAIN="empresa.local"          #Nome do Dominio
NETWORK="192.168.10.0/24"       #Rede interna para ACLsP
REVERSE_PREFIX="10.168.192"     #Parte inicial do IP ao contrario
SERIAL=$(date +%s)              #Serial unico baseado na data
LAST_OCTET=$(echo $IP | awk -F. '{print $4}') # Último octeto: 10
# =============================================================================
echo "INSTALAÇÃO DO BIND, UTILS"
dnf install -y bind bind-utils
echo "BIND instalado"

# =============================================================================
# CONFIGURAÇÃO DE LOGS E DIRETÓRIOS
# ==============================================================================
echo " "
echo "CONFIGURAÇÃO DE LOGS E DIRETÓRIOS"
mkdir -p /var/named/data/
mkdir -p /var/log/named/
chown -R named:named /var/log/named/ # Garantir que o BIND pode escrever os logs
chcon -t named_log_t /var/log/named/ # Ajustar contexto SELinux para logs

tee /etc/named.conf > /dev/null <<EOF
acl internal-network {
    $NETWORK;
};

options {
    listen-on port 53 { any; };
    listen-on-v6 port 53 { none; };
    directory            "/var/named";
    dump-file            "/var/named/data/cache_dump.db";
    statistics-file      "/var/named/data/named_stats.txt";
    memstatistics-file   "/var/named/data/named_mem_stats.txt";
    secroots-file        "/var/named/data/named.secroots";
    recursing-file       "/var/named/data/named.recursing";

    // Permitir consultas e recursão da rede interna
    allow-query { localhost; internal-network; };
    allow-recursion { localhost; internal-network; };
    allow-transfer { none; }; // Restringir transferência de zona (Requisito de Segurança)
    recursion yes;

    // REQUISITO: Configuração de Forwarding
    forward only;
    forwarders { 8.8.8.8; 8.8.4.4; };
};

// REQUISITO: Configuração de Logs de Consultas para Auditoria
logging {
    channel default_log {
        file "/var/log/named/query.log" versions 3 size 5m;
        severity info;
        print-time yes;
    };
    category queries { default_log; };
};

// Configuração da Zona Direta
zone "$DOMAIN" IN {
    type primary;
    file "$DOMAIN.db";
    allow-update { none; };
};

// Configuração da Zona Reversa
zone "$REVERSE_PREFIX.in-addr.arpa" IN {
    type primary;
    file "$REVERSE_PREFIX.db";
    allow-update { none; };
};

// Inclusões corrigidas
include "/etc/named.rfc1912.zones";
include "/etc/named.root.key";
EOF

# Ajustar a opção IPv4
echo "OPTIONS=\"-4\"" > /etc/sysconfig/named
echo "Configurações principais concluídas"

# =============================================================================
# CRIAR ARQUIVO DE ZONA DIRETA ($DOMAIN.db)
# ==============================================================================
echo "CRIAÇÃO DA ZONA DIRETA ($DOMAIN.db)"

tee /var/named/$DOMAIN.db > /dev/null <<EOF
\$TTL 86400
@    IN    SOA ${HOSTNAME_SERVER}.$DOMAIN. root.$DOMAIN. (
         $SERIAL      ; Serial
         3600         ; Refresh
         1800         ; Retry
         604800       ; Expire
         86400        ; Minimum TTL
)
         IN NS        ${HOSTNAME_SERVER}.$DOMAIN.
${HOSTNAME_SERVER} IN A    $IP
@        IN A    $IP
EOF

echo "Ficheiro da zona direta criado."

echo "  "
# =============================================================================
# CRIAR ZONA REVERSA ($REVERSE_PREFIX.db)
# ==============================================================================
echo "CRIAÇÃO DA ZONA REVERSA ($REVERSE_PREFIX.db)"

tee /var/named/$REVERSE_PREFIX.db > /dev/null <<EOF
\$TTL 86400
@    IN    SOA ${HOSTNAME_SERVER}.$DOMAIN. root.$DOMAIN. (
         $SERIAL      ; Serial
         3600         ; Refresh
         1800         ; Retry
         604800       ; Expire
         86400        ; Minimum TTL
)
         IN NS        ${HOSTNAME_SERVER}.$DOMAIN.
$LAST_OCTET IN PTR    ${HOSTNAME_SERVER}.$DOMAIN.
EOF

echo "Ficheiro da zona reversa criado"

# =============================================================================
# PERMISSÕES, SELINUX E FIREWALL (REQUISITOS DE SEGURANÇA)
# ==============================================================================

echo "AJUSTE DE PERMISSÕES, SELINUX E FIREWALL"

# Permissões e Propriedade
echo "Configurando propriedade e permissões"
chown root:named /etc/named.conf
chown named:named /var/named/$DOMAIN.db /var/named/$REVERSE_PREFIX.db
chmod 640 /etc/named.conf
chmod 640 /var/named/$DOMAIN.db /var/named/$REVERSE_PREFIX.db

# SELinux: Restaurar o contexto de segurança
echo "Restaurando contextos SELinux nos ficheiros de zona"
restorecon -Rv /var/named

# Firewalld (REQUISITO: DNS porta 53/UDP/TCP)
echo "Configurando Firewalld para porta DNS (53/UDP/TCP) (Permanente)"
firewall-cmd --zone=public --add-service=dns --permanent
firewall-cmd --reload
echo "Regra DNS adicionada e Firewalld recarregado."

# ==============================================================================
# VALIDAÇÃO E ATIVAÇÃO DO SERVIÇO BIND
# ==============================================================================
echo "Verificando, Ativando e Iniciando o Serviço BIND"

# Validar ficheiros antes de iniciar
named-checkconf || { echo "Erro na configuração named.conf. Abortando."; exit 1; }
named-checkzone $DOMAIN /var/named/$DOMAIN.db || { echo "Erro na zona direta. Abortando."; exit 1; }
named-checkzone $REVERSE_PREFIX.in-addr.arpa /var/named/$REVERSE_PREFIX.db || { echo "Erro na zona inversa. Abortando."; exit 1; }

# Ativar e iniciar o serviço
systemctl enable named
systemctl restart named

# ==============================================================================
# CONFIGURAR O SERVIDOR PARA USAR O PRÓPRIO DNS
# ==============================================================================

echo "Configurando o próprio servidor para usar o DNS local ($IP)"

# Detectar a interface de rede ativa
INTERFACE=$(nmcli -t -f DEVICE,STATE dev status | grep ":connected" | cut -d: -f1)

echo "  "
echo "Script de DNS concluído e pronto para a demonstração!"


