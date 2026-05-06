#!/bin/bash

set -e

# Colores para la consola
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

REGION="us-east-1"                 
VPC_CIDR="10.10.0.0/16"            
SUBNET_CIDR="10.10.1.0/24"         
AZ="us-east-1a"                    
INSTANCE_TYPE="t3.medium"          
INSTANCE_NAME="AD-Controlador-UFV" 
PRIVATE_IP="10.10.1.10"            
KEY_NAME="clave-practica"             
AMI_ID="ami-0fc5d935ebf8bc3bc"     
LB_CIDR="0.0.0.0/0"             

# Etiquetas para identificar los backups
BACKUP_TAG_KEY="BackupType"
BACKUP_TAG_VALUE="AD-UFV-Backup"

# Funciones de log
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[⚠️ ]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }

check_backup_amis() {
  aws ec2 describe-images --owners self \
    --filters "Name=tag:${BACKUP_TAG_KEY},Values=${BACKUP_TAG_VALUE}" \
    --region "$REGION" --query 'Images' --output json 2>/dev/null | jq length
}

create_backup() {
  log_info "Iniciando proceso de Backup (Snapshot + AMI)..."
  
  # Obtener el ID del volumen de la instancia actual
  VOLUME_ID=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=$INSTANCE_NAME" "Name=instance-state-name,Values=running" \
    --region "$REGION" --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' --output text)

  if [ "$VOLUME_ID" == "None" ] || [ -z "$VOLUME_ID" ]; then
    log_error "No se encontró la instancia $INSTANCE_NAME en ejecución para hacer backup."
    return 1
  fi

  log_info "Creando Snapshot del volumen $VOLUME_ID..."
  SNAPSHOT_ID=$(aws ec2 create-snapshot --volume-id "$VOLUME_ID" \
    --description "Backup AD UFV $(date +%Y-%m-%d)" --region "$REGION" \
    --tag-specifications "ResourceType=snapshot,Tags=[{Key=${BACKUP_TAG_KEY},Value=${BACKUP_TAG_VALUE}},{Key=Name,Value=Snapshot-AD}]" \
    --query 'SnapshotId' --output text)

  log_info "Creando AMI de la instancia..."
  BACKUP_AMI=$(aws ec2 create-image --instance-id $(aws ec2 describe-instances --filters "Name=tag:Name,Values=$INSTANCE_NAME" --region "$REGION" --query 'Reservations[0].Instances[0].InstanceId' --output text) \
    --name "Backup-AD-UFV-$(date +%s)" --no-reboot \
    --region "$REGION" --tag-specifications "ResourceType=image,Tags=[{Key=${BACKUP_TAG_KEY},Value=${BACKUP_TAG_VALUE}}]" \
    --query 'ImageId' --output text)

  log_success "Backup solicitado: AMI ($BACKUP_AMI) | Snapshot ($SNAPSHOT_ID)"
  log_info "Esperando a que la AMI esté disponible (esto tarda unos minutos)..."
  aws ec2 wait image-available --image-ids "$BACKUP_AMI" --region "$REGION"
  log_success "Backup completado y disponible."
}

restore_from_backup() {
  log_info "Iniciando restauración desde el último backup..."

  BACKUP_AMI=$(aws ec2 describe-images --owners self \
    --filters "Name=tag:${BACKUP_TAG_KEY},Values=${BACKUP_TAG_VALUE}" \
    --region "$REGION" --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
    --output text)

  if [ -z "$BACKUP_AMI" ] || [ "$BACKUP_AMI" == "None" ]; then
    log_error "No se encontró ninguna AMI de backup válida."
    return 1
  fi
  
  log_success "AMI de respaldo encontrada: $BACKUP_AMI"

  # 1. Verificar/Crear VPC
  VPC_ID=$(aws ec2 describe-vpcs --filters "Name=cidr,Values=${VPC_CIDR}" --region "$REGION" --query 'Vpcs[0].VpcId' --output text)
  if [ "$VPC_ID" == "None" ]; then
    VPC_ID=$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" --region "$REGION" --query 'Vpc.VpcId' --output text)
    aws ec2 create-tags --resources "$VPC_ID" --tags "Key=Name,Value=VPC-AD-UFV" --region "$REGION"
    log_success "VPC creada: $VPC_ID"
  fi

  # 2. Verificar/Crear Subnet
  SUBNET_ID=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" "Name=cidr-block,Values=${SUBNET_CIDR}" --region "$REGION" --query 'Subnets[0].SubnetId' --output text)
  if [ "$SUBNET_ID" == "None" ]; then
    SUBNET_ID=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$SUBNET_CIDR" --availability-zone "$AZ" --region "$REGION" --query 'Subnet.SubnetId' --output text)
    log_success "Subnet creada: $SUBNET_ID"
  fi

  # 3. Lanzar Instancia desde AMI
  INSTANCE_ID=$(aws ec2 run-instances --image-id "$BACKUP_AMI" --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" --subnet-id "$SUBNET_ID" --private-ip-address "$PRIVATE_IP" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
    --region "$REGION" --query 'Instances[0].InstanceId' --output text)

  log_success "Instancia AD restaurada lanzándose: $INSTANCE_ID"
  aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"
  log_success "Servidor AD restaurado y funcionando en $PRIVATE_IP"
}

# --- FLUJO PRINCIPAL ---

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  log_error "AWS CLI no configurado o credenciales inválidas."
  exit 1
fi

AMI_COUNT=$(check_backup_amis)

if [ "$AMI_COUNT" -gt 0 ]; then
  log_info "Se detectaron $AMI_COUNT backups anteriores."
  read -p "¿Deseas RESTAURAR el AD desde el último backup? (s/N): " -r
  if [[ $REPLY =~ ^[Ss]$ ]]; then
    restore_from_backup
    exit 0
  fi
fi

read -p "¿Deseas crear un nuevo BACKUP del AD actual? (s/N): " -r
if [[ $REPLY =~ ^[Ss]$ ]]; then
  create_backup
  exit 0
fi

log_info "No se realizó ninguna acción."
