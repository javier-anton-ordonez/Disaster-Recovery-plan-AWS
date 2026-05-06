#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Informacion que hay que cambiar dependiendo de la instancia de linux server que se haga
REGION="eu-west-1"
VPC_CIDR="10.30.0.0/16"
SUBNET_CIDR="10.30.1.0/24"
AZ="eu-west-1a"
INSTANCE_TYPE="t3.small"
INSTANCE_NAME="EC2-Profesores-Javier_2"
PRIVATE_IP="10.30.1.11"
KEY_NAME="key-javier"
AMI_ID="ami-04a783118f87be8a0"
LB_CIDR="10.20.0.0/16"

BACKUP_TAG_KEY="BackupType"
BACKUP_TAG_VALUE="Profesores-C"

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[⚠️ ]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }

check_backup_snapshots() {
  aws ec2 describe-snapshots --owner-ids self \
    --filters "Name=tag:${BACKUP_TAG_KEY},Values=${BACKUP_TAG_VALUE}" \
    --region "$REGION" --query 'Snapshots[?State==`completed`]' \
    --output json 2>/dev/null | jq length
}

check_backup_amis() {
  aws ec2 describe-images --owners self \
    --filters "Name=tag:${BACKUP_TAG_KEY},Values=${BACKUP_TAG_VALUE}" \
    --region "$REGION" --query 'Images' --output json 2>/dev/null | jq length
}

restore_from_backup() {
  log_info "Restaurando desde backup..."

  BACKUP_AMI=$(aws ec2 describe-images --owners self \
    --filters "Name=tag:${BACKUP_TAG_KEY},Values=${BACKUP_TAG_VALUE}" \
    --region "$REGION" --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
    --output text)

  [ -z "$BACKUP_AMI" ] || [ "$BACKUP_AMI" == "None" ] && {
    log_warning "Backup AMI no válido"
    return 1
  }
  log_success "AMI encontrada: $BACKUP_AMI"

  VPC_ID=$(aws ec2 describe-vpcs --filters "Name=cidr,Values=${VPC_CIDR}" \
    --region "$REGION" --query 'Vpcs[0].VpcId' --output text 2>/dev/null)

  if [ -z "$VPC_ID" ] || [ "$VPC_ID" == "None" ]; then
    VPC_ID=$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" --region "$REGION" \
      --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=VPC-Profesores-C}]" \
      --query 'Vpc.VpcId' --output text)
    aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames --region "$REGION"
    aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support --region "$REGION"
    log_success "VPC creada: $VPC_ID"
  else
    log_success "VPC existente: $VPC_ID"
  fi

  SUBNET_ID=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" \
    "Name=cidr-block,Values=${SUBNET_CIDR}" --region "$REGION" \
    --query 'Subnets[0].SubnetId' --output text 2>/dev/null)

  if [ -z "$SUBNET_ID" ] || [ "$SUBNET_ID" == "None" ]; then
    SUBNET_ID=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$SUBNET_CIDR" \
      --availability-zone "$AZ" --region "$REGION" \
      --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=Subnet-Profesores}]" \
      --query 'Subnet.SubnetId' --output text)
    log_success "Subnet creada: $SUBNET_ID"
  else
    log_success "Subnet existente: $SUBNET_ID"
  fi

  IGW_ID=$(aws ec2 describe-internet-gateways \
    --filters "Name=attachment.vpc-id,Values=${VPC_ID}" --region "$REGION" \
    --query 'InternetGateways[0].InternetGatewayId' --output text 2>/dev/null)

  if [ -z "$IGW_ID" ] || [ "$IGW_ID" == "None" ]; then
    IGW_ID=$(aws ec2 create-internet-gateway --region "$REGION" \
      --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=IGW-Profesores}]" \
      --query 'InternetGateway.InternetGatewayId' --output text)
    aws ec2 attach-internet-gateway --vpc-id "$VPC_ID" --internet-gateway-id "$IGW_ID" --region "$REGION"
    log_success "IGW creado: $IGW_ID"
  else
    log_success "IGW existente: $IGW_ID"
  fi

  RT_ID=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=${VPC_ID}" \
    "Name=tag:Name,Values=RT-Profesores" --region "$REGION" \
    --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null)

  if [ -z "$RT_ID" ] || [ "$RT_ID" == "None" ]; then
    RT_ID=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --region "$REGION" \
      --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=RT-Profesores}]" \
      --query 'RouteTable.RouteTableId' --output text)
    aws ec2 create-route --route-table-id "$RT_ID" --destination-cidr-block 0.0.0.0/0 \
      --gateway-id "$IGW_ID" --region "$REGION" 2>/dev/null || true
    aws ec2 associate-route-table --subnet-id "$SUBNET_ID" --route-table-id "$RT_ID" \
      --region "$REGION" 2>/dev/null || true
    log_success "Route Table creada: $RT_ID"
  else
    log_success "Route Table existente: $RT_ID"
  fi

  SG_ID=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=${VPC_ID}" \
    "Name=group-name,Values=SG-Profesores" --region "$REGION" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)

  if [ -z "$SG_ID" ] || [ "$SG_ID" == "None" ]; then
    SG_ID=$(aws ec2 create-security-group --group-name SG-Profesores \
      --description "Security Group para Web Server Profesores" \
      --vpc-id "$VPC_ID" --region "$REGION" --query 'GroupId' --output text)
    aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp \
      --port 22 --cidr 0.0.0.0/0 --region "$REGION" >/dev/null 2>&1 || true
    aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp \
      --port 80 --cidr "$LB_CIDR" --region "$REGION" >/dev/null 2>&1 || true
    aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp \
      --port 443 --cidr "$LB_CIDR" --region "$REGION" >/dev/null 2>&1 || true
    aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp \
      --port 5432 --cidr "$LB_CIDR" --region "$REGION" >/dev/null 2>&1 || true
    log_success "SG creado: $SG_ID"
  else
    log_success "SG existente: $SG_ID"
  fi

  ALLOC_ID=$(aws ec2 allocate-address --domain vpc --region "$REGION" \
    --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=EIP-Profesores}]" \
    --query 'AllocationId' --output text)

  ELASTIC_IP=$(aws ec2 describe-addresses --allocation-ids "$ALLOC_ID" --region "$REGION" \
    --query 'Addresses[0].PublicIp' --output text)

  INSTANCE_ID=$(aws ec2 run-instances --image-id "$BACKUP_AMI" --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" --subnet-id "$SUBNET_ID" --private-ip-address "$PRIVATE_IP" \
    --security-group-ids "$SG_ID" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
    --monitoring Enabled=false --region "$REGION" --query 'Instances[0].InstanceId' --output text)

  log_success "EC2 lanzada: $INSTANCE_ID"

  aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"
  aws ec2 associate-address --instance-id "$INSTANCE_ID" --allocation-id "$ALLOC_ID" --region "$REGION" >/dev/null
  log_success "EIP asociada: $ELASTIC_IP"

  return 0
}

create_backup() {
  log_info "Creando backup..."
  sleep 120

  VOLUME_ID=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$REGION" \
    --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' --output text)

  SNAPSHOT_ID=$(aws ec2 create-snapshot --volume-id "$VOLUME_ID" \
    --description "Backup Profesores-C $(date +%Y-%m-%d\ %H:%M:%S)" --region "$REGION" \
    --tag-specifications "ResourceType=snapshot,Tags=[{Key=${BACKUP_TAG_KEY},Value=${BACKUP_TAG_VALUE}}]" \
    --query 'SnapshotId' --output text)

  BACKUP_AMI=$(aws ec2 create-image --instance-id "$INSTANCE_ID" \
    --name "Backup-Profesores-C-$(date +%s)" --description "Backup $(date +%Y-%m-%d)" \
    --region "$REGION" --tag-specifications "ResourceType=image,Tags=[{Key=${BACKUP_TAG_KEY},Value=${BACKUP_TAG_VALUE}}]" \
    --query 'ImageId' --output text)

  aws ec2 wait image-available --image-ids "$BACKUP_AMI" --region "$REGION"
  log_success "Backup creado - AMI: $BACKUP_AMI | Snapshot: $SNAPSHOT_ID"
}

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  log_error "AWS CLI no configurado"
  exit 1
fi

if ! aws ec2 describe-key-pairs --key-names "$KEY_NAME" --region "$REGION" >/dev/null 2>&1; then
  log_error "Key pair no existe"
  exit 1
fi

AMI_COUNT=$(check_backup_amis)

if [ "$AMI_COUNT" -gt 0 ]; then
  log_info "Backup encontrado"
  read -p "¿Restaurar? (s/N): " -r
  if [[ $REPLY =~ ^[Ss]$ ]]; then
    restore_from_backup && create_backup

    cat >vpc_vars_recovered.txt <<VARS

VPC_ID=$VPC_ID
SUBNET_ID=$SUBNET_ID
IGW_ID=$IGW_ID
RT_ID=$RT_ID
SG_ID=$SG_ID
INSTANCE_ID=$INSTANCE_ID
ELASTIC_IP=$ELASTIC_IP
BACKUP_AMI=$BACKUP_AMI
SNAPSHOT_ID=$SNAPSHOT_ID
RESTORATION_TYPE=FROM_BACKUP
VARS

    log_success "Restauración completada"
    echo ""
    echo "ssh -i key-javier.pem ec2-user@$ELASTIC_IP"
    exit 0
  fi
fi

read -p "¿Crear infraestructura desde cero? (s/N): " -r
[ ! $REPLY =~ ^[Ss]$ ] && exit 0

VPC_ID=$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" --region "$REGION" \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=VPC-Profesores-C}]" \
  --query 'Vpc.VpcId' --output text)
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames --region "$REGION"
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support --region "$REGION"

SUBNET_ID=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$SUBNET_CIDR" \
  --availability-zone "$AZ" --region "$REGION" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=Subnet-Profesores}]" \
  --query 'Subnet.SubnetId' --output text)

IGW_ID=$(aws ec2 create-internet-gateway --region "$REGION" \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=IGW-Profesores}]" \
  --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --vpc-id "$VPC_ID" --internet-gateway-id "$IGW_ID" --region "$REGION"

RT_ID=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --region "$REGION" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=RT-Profesores}]" \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id "$RT_ID" --destination-cidr-block 0.0.0.0/0 \
  --gateway-id "$IGW_ID" --region "$REGION"
aws ec2 associate-route-table --subnet-id "$SUBNET_ID" --route-table-id "$RT_ID" --region "$REGION" >/dev/null

SG_ID=$(aws ec2 create-security-group --group-name SG-Profesores \
  --description "Security Group Profesores" --vpc-id "$VPC_ID" --region "$REGION" \
  --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 22 \
  --cidr 0.0.0.0/0 --region "$REGION" >/dev/null
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 80 \
  --cidr "$LB_CIDR" --region "$REGION" >/dev/null
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 443 \
  --cidr "$LB_CIDR" --region "$REGION" >/dev/null
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 5432 \
  --cidr "$LB_CIDR" --region "$REGION" >/dev/null

ALLOC_ID=$(aws ec2 allocate-address --domain vpc --region "$REGION" \
  --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=EIP-Profesores}]" \
  --query 'AllocationId' --output text)
ELASTIC_IP=$(aws ec2 describe-addresses --allocation-ids "$ALLOC_ID" --region "$REGION" \
  --query 'Addresses[0].PublicIp' --output text)

cat >/tmp/userdata.sh <<'USERDATA'
#!/bin/bash
yum update -y
yum install -y git curl wget nano vim htop postgresql15 docker nginx
systemctl start docker && systemctl enable docker && usermod -aG docker ec2-user
mkdir -p ~/.docker/cli-plugins
curl -L https://github.com/docker/buildx/releases/download/v0.17.1/buildx-v0.17.1.linux-amd64 \
  -o ~/.docker/cli-plugins/docker-buildx && chmod +x ~/.docker/cli-plugins/docker-buildx
curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
  -o /usr/local/bin/docker-compose && chmod +x /usr/local/bin/docker-compose
systemctl start nginx && systemctl enable nginx
mkdir -p /home/ec2-user/app/{frontend,backend} && chown -R ec2-user:ec2-user /home/ec2-user/app
USERDATA

INSTANCE_ID=$(aws ec2 run-instances --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" \
  --key-name "$KEY_NAME" --subnet-id "$SUBNET_ID" --private-ip-address "$PRIVATE_IP" \
  --security-group-ids "$SG_ID" --user-data file:///tmp/userdata.sh \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
  --monitoring Enabled=false --region "$REGION" --query 'Instances[0].InstanceId' --output text)

log_success "EC2 lanzada: $INSTANCE_ID"

aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"
aws ec2 associate-address --instance-id "$INSTANCE_ID" --allocation-id "$ALLOC_ID" --region "$REGION" >/dev/null

create_backup

cat >vpc_vars_recovered.txt <<VARS
VPC_ID=$VPC_ID
SUBNET_ID=$SUBNET_ID
IGW_ID=$IGW_ID
RT_ID=$RT_ID
SG_ID=$SG_ID
INSTANCE_ID=$INSTANCE_ID
ELASTIC_IP=$ELASTIC_IP
BACKUP_AMI=$BACKUP_AMI
SNAPSHOT_ID=$SNAPSHOT_ID
RESTORATION_TYPE=NEW_INFRASTRUCTURE_WITH_BACKUP
VARS

log_success "Infraestructura creada"
echo ""
echo "ssh -i key-javier.pem ec2-user@$ELASTIC_IP"
echo ""

rm -f /tmp/userdata.sh
