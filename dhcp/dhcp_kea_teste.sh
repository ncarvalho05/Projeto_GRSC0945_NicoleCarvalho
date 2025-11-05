#!/bin/bash

# ==============================================================================
# SCRIPT DE CONFIGURAÇÃO FINAL: CENTOS GATEWAY (NAT + HOST-ONLY) - VERSÃO LIMPA
# ==============================================================================
# CORREÇÃO CRÍTICA: Bloco 'tee' reescrito para eliminar o erro 'Invalid character: ≡' 
# na linha 3 do kea-dhcp4.conf, que impedia o serviço de iniciar (status=1/FAILURE).
# DNS Servidor: 192.168.10.10. Gateway: 192.168.10.1.
# ==============================================================================

# ------------------------------------------------------------------------------
# 0. VARIÁVEIS DE REDE INTERATIVAS (read -p)
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
read -p "7. DNS Server (IP do seu futuro servidor) [192.168.10.10]: " DNS_SERVER
DNS_SERVER=${DNS_SERVER:-192.168.10.10}

read -p "8. Nome de Domínio [empresa.local]: " DOMAIN_NAME
DOMAIN_NAME=${DOMAIN_NAME:-empresa.local}

echo "---------------------------------------------------------------"
echo "Configurações registadas. A iniciar a execução..."
echo "---------------------------------------------------------------"

# ------------------------------------------------------------------------------
# 1. GARANTIR QUE ens160 TENHA IP (DHCP) - Internet
# ------------------------------------------------------------------------------
echo "1. Configurando $EXTERNAL_IF para DHCP (Internet via NAT)..."
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
# 3. CONFIGURAÇÃO IP ESTÁTICO DA INTERFACE INTERNA (ens224)
# ------------------------------------------------------------------------------
echo "3. Configurando IP Estático na interface $INTERNAL_IF ($INTERNAL_GATEWAY)..."
sudo nmcli connection down "$INTERNAL_IF" 2>/dev/null
sudo nmcli connection delete "$INTERNAL_IF" 2>/dev/null
sudo nmcli connection add type ethernet con-name "$INTERNAL_IF" ifname "$INTERNAL_IF"
sudo nmcli connection modify "$INTERNAL_IF" ipv4.method manual ipv4.addresses "$INTERNAL_GATEWAY/24" connection.autoconnect yes
sudo nmcli connection up "$INTERNAL_IF"

# ------------------------------------------------------------------------------
# 4. CONFIGURAÇÃO DHCP (KEA) - Usando a sua estrutura JSON
# ------------------------------------------------------------------------------
echo "4. Configurando o ficheiro kea-dhcp4.conf..."
if [ -f /etc/kea/kea-dhcp4.conf ]; then sudo mv /etc/kea/kea-dhcp4.conf /etc/kea/kea-dhcp4.conf.org; fi

# NOTE: Bloco 'EOF' reescrito para garantir a limpeza de caracteres invisíveis
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
            "pools": [
                { "pool": "$IP_POOL_START-$IP_POOL_END" }
            ],
            "option-data": [
                {
                    "name": "routers",
                    "data": "$INTERNAL_GATEWAY"
                }
            ]
        }
    ],
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
EOF

echo "   -> Ajustando permissões e propriedade do ficheiro de configuração..."
sudo chown root:kea /etc/kea/kea-dhcp4.conf
sudo chmod 640 /etc/kea/kea-dhcp4.conf
echo "   -> Ficheiro Kea configurado."

# --------------------------------------------------------------
# 4.1. GARANTIR A PASTA DE LOG E PERMISSÕES + VERIFICAR SINTAXE
# --------------------------------------------------------------
echo "4.1. Verificando a configuração Kea e garantindo permissões de log..."
sudo mkdir -p /var/log/kea
sudo chown kea:kea /var/log/kea
sudo chmod 770 /var/log/kea

# Verificar a sintaxe do JSON
echo "   -> A verificar a sintaxe do JSON. Se falhar, o erro aparecerá aqui!"
sudo /usr/sbin/kea-dhcp4 -t /etc/kea/kea-dhcp4.conf
if [ $? -ne 0 ]; then
    echo "   !!! ERRO FATAL DE SINTAXE NO FICHEIRO DE CONFIGURAÇÃO KEA !!!"
    echo "   O serviço VAI FALHAR. VERIFIQUE O OUTPUT IMEDIATAMENTE ACIMA."
    exit 1
fi
echo "   -> Sintaxe do Kea OK."
# --------------------------------------------------------------

# ------------------------------------------------------------------------------
# 5. CONFIGURAÇÃO DE ROTEAMENTO E FIREWALL (NAT)
# ------------------------------------------------------------------------------
echo "5. Configurando Roteamento IP e Firewall NAT (Masquerading)..."
echo "net.ipv4.ip_forward = 1" | sudo tee /etc/sysctl.d/99-ipforward.conf
sudo sysctl -p /etc/sysctl.d/99-ipforward.conf

# Configurar Firewall
sudo firewall-cmd --zone=external --change-interface="$EXTERNAL_IF" --permanent
sudo firewall-cmd --zone=external --add-masquerade --permanent
sudo firewall-cmd --zone=internal --add-interface="$INTERNAL_IF" --permanent
sudo firewall-cmd --add-service=dhcp --zone=internal --permanent
sudo firewall-cmd --reload
echo "   -> Roteamento e regras de Firewall ativados."

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