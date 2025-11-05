#!/bin/bash

# ==============================================================================
# SCRIPT DE CONFIGURAÇÃO FINAL: CENTOS GATEWAY (NAT + HOST-ONLY)
# ==============================================================================
# Baseado na sua configuração de rede: ens160 (Internet/NAT) e ens224 (Cliente/Host-only).
# Correção: Adicionada verificação de sintaxe e criação/permissões da pasta de log do Kea.
# ==============================================================================

# VARIÁVEIS DE REDE AJUSTADAS
EXTERNAL_IF="ens160"                # Interface de Internet
INTERNAL_IF="ens224"                # Interface de Cliente (Host-only - Adaptador 2)
INTERNAL_SUBNET="192.168.10.0/24"   # Sub-rede interna para clientes
INTERNAL_GATEWAY="192.168.10.1"     # IP Estático do ens224 (Gateway para o Cliente)
IP_POOL_START="192.168.10.100"
IP_POOL_END="192.168.10.199"
DNS_SERVER="8.8.8.8"                # DNS Público (para evitar problemas de resolução)
DOMAIN_NAME="empresa.local"         # Seu nome de domínio

# ------------------------------------------------------------------------------
# 1. GARANTIR QUE ens160 TENHA IP (DHCP) - Internet
# ------------------------------------------------------------------------------
echo "1. Configurando $EXTERNAL_IF para DHCP (Internet via NAT)..."
nmcli connection down "$EXTERNAL_IF" 2>/dev/null
nmcli connection delete "$EXTERNAL_IF" 2>/dev/null
nmcli connection add type ethernet con-name "$EXTERNAL_IF-NAT" ifname $EXTERNAL_IF
nmcli connection modify "$EXTERNAL_IF-NAT" ipv4.method auto connection.autoconnect yes
nmcli connection up "$EXTERNAL_IF-NAT"

# ------------------------------------------------------------------------------
# 2. INSTALAR KEA DHCP
echo "2. Instalando o pacote Kea DHCP..."
sudo dnf -y install kea

# ------------------------------------------------------------------------------
# 3. CONFIGURAÇÃO IP ESTÁTICO DA INTERFACE INTERNA (ens224)
# ------------------------------------------------------------------------------
echo "3. Configurando IP Estático na interface $INTERNAL_IF ($INTERNAL_GATEWAY)..."
nmcli connection down "$INTERNAL_IF" 2>/dev/null
nmcli connection delete "$INTERNAL_IF" 2>/dev/null
nmcli connection add type ethernet con-name "$INTERNAL_IF" ifname $INTERNAL_IF
# Atenção: Assegurar que 'connection.autoconnect yes' está correto no seu terminal, ou usar 'auto'
nmcli connection modify "$INTERNAL_IF" ipv4.method manual ipv4.addresses $INTERNAL_GATEWAY/24 connection.autoconnect yes
nmcli connection up "$INTERNAL_IF"

# ------------------------------------------------------------------------------
# 4. CONFIGURAÇÃO DHCP (KEA) - Usando a sua estrutura JSON
# ------------------------------------------------------------------------------
echo "4. Configurando o ficheiro kea-dhcp4.conf..."
if [ -f /etc/kea/kea-dhcp4.conf ]; then sudo mv /etc/kea/kea-dhcp4.conf /etc/kea/kea-dhcp4.conf.org; fi

sudo tee /etc/kea/kea-dhcp4.conf > /dev/null << EOF
{
"Dhcp4": {
    "interfaces-config": {
        // Corrigido para a interface interna: ens224
        "interfaces": [ "$INTERNAL_IF" ]
    },
    // processamento de leases expirados (mantido do seu script)
    "expired-leases-processing": {
        "reclaim-timer-wait-time": 10,
        "flush-reclaimed-timer-wait-time": 25,
        "hold-reclaimed-time": 3600,
        "max-reclaim-leases": 100,
        "max-reclaim-time": 250,
        "unwarned-reclaim-cycles": 5
    },
    // temporizadores DHCP (mantido do seu script)
    "renew-timer": 900,
    "rebind-timer": 1800,
    "valid-lifetime": 3600,

    // opções gerais (DNS e domínio corrigidos)
    "option-data": [
        {
            // Usando DNS 8.8.8.8 para garantir acesso à internet
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

    // definição de sub-rede e pool (Corrigidos para 192.168.10.x)
    "subnet4": [
        {
            "id": 1,
            "subnet": "$INTERNAL_SUBNET",
            "pools": [
                { "pool": "$IP_POOL_START - $IP_POOL_END" }
            ],
            "option-data": [
                {
                    // Gateway corrigido para o IP estático do CentOS: 192.168.10.1
                    "name": "routers",
                    "data": "$INTERNAL_GATEWAY"
                }
            ]
        }
    ],

    // configuração de logs (mantido do seu script)
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

# Ajustar permissões e propriedade
echo "   -> Ajustando permissões e propriedade do ficheiro de configuração..."
sudo chown root:kea /etc/kea/kea-dhcp4.conf
sudo chmod 640 /etc/kea/kea-dhcp4.conf
echo "   -> Ficheiro Kea configurado."

# --- NOVO PASSO DE CORREÇÃO ---
# 4.1. GARANTIR A PASTA DE LOG E PERMISSÕES + VERIFICAR SINTAXE
# --------------------------------------------------------------
echo "4.1. Verificando a configuração Kea e garantindo permissões de log..."
# 1. Criar a pasta de log (se não existir) e dar permissão ao grupo 'kea'
sudo mkdir -p /var/log/kea
sudo chown kea:kea /var/log/kea
sudo chmod 770 /var/log/kea # Permite a escrita do Kea

# 2. Verificar a sintaxe do JSON (Isto deve indicar o erro 'status=1/FAILURE')
echo "   -> A verificar a sintaxe do JSON. Se falhar, é erro no ficheiro!"
/usr/sbin/kea-dhcp4 -t /etc/kea/kea-dhcp4.conf
if [ $? -ne 0 ]; then
    echo "   !!! ERRO FATAL DE SINTAXE NO FICHEIRO DE CONFIGURAÇÃO KEA !!!"
    echo "   O serviço VAI FALHAR. Corrija /etc/kea/kea-dhcp4.conf e tente novamente."
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

# Configurar Firewall (Adicionar DHCP à zona interna e Masquerading à externa)
sudo firewall-cmd --zone=external --change-interface=$EXTERNAL_IF --permanent
sudo firewall-cmd --zone=external --add-masquerade --permanent
sudo firewall-cmd --zone=internal --add-interface=$INTERNAL_IF --permanent
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