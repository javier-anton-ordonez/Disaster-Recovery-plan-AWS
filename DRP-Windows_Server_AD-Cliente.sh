#!/bin/bash

REGION="eu-west-1"
AZ="eu-west-1a"

# SNAPSHOTS
SNAP_AD="snap-014c3d19e54a923b3"
SNAP_CLIENT="snap-00f465837cf5f93c9"

# CONFIG
AMI="ami-0936d559e78767b97"
INSTANCE_TYPE="t3.small"
KEY_NAME="clave-practica"
SUBNET_ID="subnet-03b79e83ed8e003a4"
SG_ID="sg-06b068667882be6af"
EIP_ALLOC="eipalloc-0b328fcc12f23c71b"


# ================= AD ================= #

echo "[AD] Creando volumen desde snapshot..."
VOL_AD=$(aws ec2 create-volume \
  --snapshot-id $SNAP_AD \
  --availability-zone $AZ \
  --region $REGION \
  --query 'VolumeId' \
  --output text)

aws ec2 wait volume-available --volume-ids $VOL_AD --region $REGION
echo "Volumen AD listo: $VOL_AD"

echo "[AD] Lanzando instancia..."
AD_INSTANCE=$(aws ec2 run-instances \
  --image-id $AMI \
  --instance-type $INSTANCE_TYPE \
  --key-name $KEY_NAME \
  --subnet-id $SUBNET_ID \
  --security-group-ids $SG_ID \
  --region $REGION \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=DRP-AD}]' \
  --query 'Instances[0].InstanceId' \
  --output text)

aws ec2 wait instance-running --instance-ids $AD_INSTANCE --region $REGION
echo "AD Instance: $AD_INSTANCE"

echo "[AD] Adjuntando volumen restaurado..."
aws ec2 attach-volume \
  --volume-id $VOL_AD \
  --instance-id $AD_INSTANCE \
  --device /dev/sdf \
  --region $REGION

echo "[AD] Asociando Elastic IP..."
aws ec2 associate-address \
  --instance-id $AD_INSTANCE \
  --allocation-id $EIP_ALLOC \
  --region $REGION

# ================= CLIENTE ================= #

echo "[CLIENTE] Creando volumen desde snapshot..."
VOL_CLIENT=$(aws ec2 create-volume \
  --snapshot-id $SNAP_CLIENT \
  --availability-zone $AZ \
  --region $REGION \
  --query 'VolumeId' \
  --output text)

aws ec2 wait volume-available --volume-ids $VOL_CLIENT --region $REGION
echo "Volumen Cliente listo: $VOL_CLIENT"

echo "[CLIENTE] Lanzando instancia..."
CLIENT_INSTANCE=$(aws ec2 run-instances \
  --image-id $AMI \
  --instance-type $INSTANCE_TYPE \
  --key-name $KEY_NAME \
  --subnet-id $SUBNET_ID \
  --security-group-ids $SG_ID \
  --region $REGION \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=DRP-CLIENT}]' \
  --query 'Instances[0].InstanceId' \
  --output text)

aws ec2 wait instance-running --instance-ids $CLIENT_INSTANCE --region $REGION
echo "Cliente Instance: $CLIENT_INSTANCE"

echo "[CLIENTE] Adjuntando volumen restaurado..."
aws ec2 attach-volume \
  --volume-id $VOL_CLIENT \
  --instance-id $CLIENT_INSTANCE \
  --device /dev/sdf \
  --region $REGION


echo ""
echo "PASOS MANUALES (OBLIGATORIOS):"
echo ""
echo "1. Conectarte por RDP a la instancia AD"
echo "2. Abrir 'Disk Management'"
echo "3. Montar el volumen restaurado"
echo "4. Verificar backup en C:\\Backup-AD"
echo ""
echo "5. Validar AD:"
echo "   Get-ADDomain"
echo "   nltest /dsgetdc:ufv.local"
echo ""
echo "6. En cliente:"
echo "   whoami"
echo "   net user /domain"
echo ""
echo "7. Verificar recursos:"
echo "   \\\\ufv.local\\"
echo ""
echo "Si todo responde → recuperación completada"