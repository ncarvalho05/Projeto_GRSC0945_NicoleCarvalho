#!/bin/bash

# ==============================================================================
# SCRIPT DE CONFIGURAÇÃO CENTOS GATEWAY (NAT + HOST-ONLY)
# ==============================================================================

# ------------------------------------------------------------------------------
# VARIÁVEIS DE REDE INTERATIVAS
# ------------------------------------------------------------------------------
echo "==============================================="
echo "CONFIGURAÇÃO DE REDE - CENTOS GATEWAY (KEa)"
echo "==============================================="

# Solicitações de entrada com valores default
read -p "1. Interface de Internet (NAT) [ens160]: " EXTERNAL_IF
EXTERNAL_IF=${EXTERNAL_IF:-ens160}

read -p "2. Interface Interna (Host-only) [ens224]: " INTERNAL_IF
INTERNAL_IF=${INTERNAL_IF:-ens224}

read -p "3. Sub-rede Interna (CIDR) [192.168.10.0/24]: " INTERNAL_SUBNET
INTERNAL_SUBNET=${INTERNAL_SUBNET:-192.168.10.0/24}

read -p "4. IP Estático (Gateway Interno) [192.168.10.1]: " INTERNAL_GATEWAY
INTERNAL_GATEWAY=${INTERNAL_GATEWAY:-192.168.10.1}

read -p "5. Início do Pool DHCP [192.168.10.100]: " IP_POOL_START
IP_POOL_START=${IP_POOL_START:-192.168.10.100}

read -p "6. Fim do Pool DHCP [192.168.10.199]: " IP_POOL_END
IP_POOL_END=${IP_POOL_END:-192.168.10.199}

# DNS Interno (IP do seu futuro servidor)
read -p "7. DNS Server (IP do seu servidor DNS) [192.168.10.1]: " DNS_SERVER
DNS_SERVER=${DNS_SERVER:-192.168.10.1}

read -p "8. Nome de Domínio [empresa.local]: " DOMAIN_NAME
DOMAIN_NAME=${DOMAIN_NAME:-empresa.local}

echo "---------------------------------------------------------------"
echo "Configurações registadas. A iniciar a execução..."
echo "---------------------------------------------------------------"

# ------------------------------------------------------------------------------
# GARANTIR QUE ens160 TENHA IP (DHCP) - Internet
# ------------------------------------------------------------------------------
echo "Configurando $EXTERNAL_IF para DHCP (Internet via NAT)..."
sudo nmcli connection down "$EXTERNAL_IF" 2>/dev/null
sudo nmcli connection delete "$EXTERNAL_IF" 2>/dev/null
sudo nmcli connection add type ethernet con-name "$EXTERNAL_IF-NAT" ifname "$EXTERNAL_IF"
sudo nmcli connection modify "$EXTERNAL_IF-NAT" ipv4.method auto connection.autoconnect yes
sudo nmcli connection up "$EXTERNAL_IF-NAT"

# ------------------------------------------------------------------------------
# 2. INSTALAR KEA DHCP
echo "2. Instalando o pacote Kea DHCP..."
sudo dnf -y install kea

# ------------------------------------------------------------------------------
# CONFIGURAÇÃO IP ESTÁTICO DA INTERFACE INTERNA (ens224)
# ------------------------------------------------------------------------------
echo "Configurando IP Estático na interface $INTERNAL_IF ($INTERNAL_GATEWAY)..."
sudo nmcli connection down "$INTERNAL_IF" 2>/dev/null
sudo nmcli connection delete "$INTERNAL_IF" 2>/dev/null
sudo nmcli connection add type ethernet con-name "$INTERNAL_IF" ifname "$INTERNAL_IF"
sudo nmcli connection modify "$INTERNAL_IF" ipv4.method manual ipv4.addresses "$INTERNAL_GATEWAY/24" connection.autoconnect yes
sudo nmcli connection up "$INTERNAL_IF"

# ------------------------------------------------------------------------------
# CONFIGURAÇÃO DHCP (KEA) - Usando a sua estrutura JSON
# ------------------------------------------------------------------------------
echo "Configurando o ficheiro kea-dhcp4.conf"
if [ -f /etc/kea/kea-dhcp4.conf ]; then sudo mv /etc/kea/kea-dhcp4.conf /etc/kea/kea-dhcp4.conf.org; fi

sudo tee /etc/kea/kea-dhcp4.conf > /dev/null << EOF
{

"Dhcp4": {

    "interfaces-config": {

       "interfaces": [ "$INTERNAL_IF" ]

    },

    "expired-leases-processing": {

      "reclaim-timer-wait-time": 10,

      "flush-reclaimed-timer-wait-time": 25,

      "hold-reclaimed-time": 3600,

      "max-reclaim-leases": 100,

      "max-reclaim-time": 250,

      "unwarned-reclaim-cycles": 5

    },

    "renew-timer": 900,

    "rebind-timer": 1800,

    "valid-lifetime": 3600,

    "option-data": [

      {

        "name": "domain-name-servers",

        "data": "$DNS_SERVER"

      },

      {

        "name": "domain-name",

        "data": "$DOMAIN_NAME"

      },

      {

        "name": "domain-search",

        "data": "$DOMAIN_NAME"

      }

    ],

    "subnet4": [

      {

        "id": 1,

        "subnet": "$INTERNAL_SUBNET",

        "pools": [ { "pool": "$IP_POOL_START - $IP_POOL_END" } ],

        "option-data": [

          {

           "name": "routers",

           "data": "$INTERNAL_GATEWAY"

          }

       ]

      }

        ],

        "lease-database": {

                "type": "memfile",

                "persist": true,

                "lfc-interval": 3600,

                "name": "/var/lib/kea/dhcp4.leases"

        },

    "loggers": [

      {

        "name": "kea-dhcp4",

        "output-options": [

          {

            "output": "/var/log/kea/kea-dhcp4.log"

          }

        ],

        "severity": "INFO",

        "debuglevel": 0

      }

    ]

  }

}

EOF

echo "Ajustando permissões e propriedade do ficheiro de configuração"
sudo chown root:kea /etc/kea/kea-dhcp4.conf
sudo chmod 640 /etc/kea/kea-dhcp4.conf
echo "Ficheiro Kea configurado."

# --------------------------------------------------------------
# GARANTIR A PASTA DE LOG E PERMISSÕES + VERIFICAR SINTAXE
# --------------------------------------------------------------
echo "Verificando a configuração Kea e garantindo permissões de log"
# Cria e define as permissões UNIX para a pasta de logs
sudo mkdir -p /var/log/kea
sudo chown kea:kea /var/log/kea
sudo chmod 770 /var/log/kea

# Verificar a sintaxe do JSON
echo "verificar a sintaxe do JSON. Se falhar, o erro aparecerá aqui!"
sudo /usr/sbin/kea-dhcp4 -t /etc/kea/kea-dhcp4.conf
if [ $? -ne 0 ]; then
    echo "   !!! ERRO FATAL DE SINTAXE NO FICHEIRO DE CONFIGURAÇÃO KEA !!!"
    echo "   O serviço VAI FALHAR. VERIFIQUE O OUTPUT IMEDIATAMENTE ACIMA."
    exit 1
fi
echo "Sintaxe do Kea OK."

# --------------------------------------------------------------
# GARANTIR DIRETÓRIO DE LEASES E PERMISSÕES (CRÍTICO)
# --------------------------------------------------------------
echo "Garantindo permissões de escrita no diretório de leases (/var/lib/kea)"
# Cria e define as permissões UNIX para a pasta de leases
sudo mkdir -p /var/lib/kea
sudo chown kea:kea /var/lib/kea
sudo chmod 775 /var/lib/kea

# --------------------------------------------------------------
# AJUSTAR CONTEXTO SELINUX PARA PERSISTÊNCIA
# --------------------------------------------------------------
echo "Ajustando o contexto SELinux para bases de dados e logs DHCP (SOLUÇÃO FINAL)..."
# Garante que as ferramentas SELinux estão instaladas para usar 'semanage'
sudo dnf install -y policycoreutils-python-utils

# Define o contexto de segurança para o diretório de LEASES (/var/lib/kea)
# 'dhcpd_state_t' permite a escrita da base de dados (leases)
sudo semanage fcontext -a -t dhcpd_state_t "/var/lib/kea(/.*)?"
sudo restorecon -Rv /var/lib/kea/
echo "Contexto 'dhcpd_state_t' aplicado a /var/lib/kea (Leases)"

# Define o contexto de segurança para o diretório de LOGS (/var/log/kea)
# 'var_log_t' permite a escrita dos ficheiros de log
sudo semanage fcontext -a -t var_log_t "/var/log/kea(/.*)?"
sudo restorecon -Rv /var/log/kea/
echo "Contexto 'var_log_t' aplicado a /var/log/kea (Logs)."
echo "Kea pode agora criar e escrever ficheiros persistentes."

# ------------------------------------------------------------------------------
# 5. CONFIGURAÇÃO DE ROTEAMENTO E FIREWALL (NAT)
# ------------------------------------------------------------------------------
echo "Configurando Roteamento IP e Firewall NAT"
echo "net.ipv4.ip_forward = 1" | sudo tee /etc/sysctl.d/99-ipforward.conf
sudo sysctl -p /etc/sysctl.d/99-ipforward.conf

# Configurar Firewall
sudo firewall-cmd --zone=external --change-interface="$EXTERNAL_IF" --permanent
sudo firewall-cmd --zone=external --add-masquerade --permanent
sudo firewall-cmd --zone=internal --add-interface="$INTERNAL_IF" --permanent
sudo firewall-cmd --add-service=dhcp --zone=internal --permanent
sudo firewall-cmd --reload
echo "Roteamento e regras de Firewall ativados."

# ------------------------------------------------------------------------------
# 6. INICIAR O SERVIÇO KEA
# ------------------------------------------------------------------------------
echo "6. Habilitando e iniciando o serviço kea-dhcp4..."
sudo systemctl enable --now kea-dhcp4

# Verificação Final
echo "7. Verificação de estado do serviço:"
sudo systemctl status kea-dhcp4 | grep Active

echo ""
echo "Script de configuração de Gateway concluído!"
