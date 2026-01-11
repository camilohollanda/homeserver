# Whisper GPU Inference Server

GPU-accelerated speech-to-text transcription using [faster-whisper](https://github.com/SYSTRAN/faster-whisper) with the `large-v3-turbo` model.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      Proxmox Host                           │
├──────────────────┬──────────────────────────────────────────┤
│   k3s-apps VM    │         whisper-gpu VM                   │
│   192.168.20.11  │         192.168.20.30                    │
│                  │                                          │
│ ┌──────────────┐ │  ┌─────────────────────────────────────┐ │
│ │  werify app  │────▶│  Whisper API (FastAPI)             │ │
│ │  port 4000   │ │  │  port 8000                          │ │
│ └──────────────┘ │  │                                     │ │
│                  │  │  Model: large-v3-turbo              │ │
│                  │  │  GPU: Quadro M4000 (8GB)            │ │
│                  │  └─────────────────────────────────────┘ │
└──────────────────┴──────────────────────────────────────────┘
```

## Prerequisites

### 1. Enable IOMMU on Proxmox Host

SSH into the Proxmox host and configure IOMMU:

```bash
ssh root@192.168.20.10
```

Edit GRUB configuration:

```bash
# For Intel CPU
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="quiet"/GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt"/' /etc/default/grub

# For AMD CPU
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="quiet"/GRUB_CMDLINE_LINUX_DEFAULT="quiet amd_iommu=on iommu=pt"/' /etc/default/grub

# Update GRUB
update-grub
```

Load VFIO modules (using modern modules-load.d):

```bash
cat > /etc/modules-load.d/vfio.conf << EOF
vfio
vfio_iommu_type1
vfio_pci
EOF
```

Blacklist NVIDIA driver on host (so guest can use it):

```bash
cat > /etc/modprobe.d/blacklist-nvidia.conf << EOF
blacklist nouveau
blacklist nvidia
blacklist nvidiafb
blacklist nvidia_drm
EOF

# Configure VFIO to grab the GPU
# Use your GPU's PCI IDs from: lspci -nn | grep -i nvidia
echo "options vfio-pci ids=10de:13f1,10de:0fbb" > /etc/modprobe.d/vfio.conf

update-initramfs -u
reboot
```

After reboot, verify IOMMU is enabled:

```bash
dmesg | grep -i iommu
# Should show: "IOMMU enabled"
```

### 2. Verify GPU IOMMU Group Isolation

Before creating the PCI mapping, verify your GPU is properly isolated:

```bash
# List all devices in the GPU's IOMMU group with full details
for dev in /sys/kernel/iommu_groups/52/devices/*; do
  echo "=== $(basename $dev) ==="
  lspci -nns $(basename $dev)
done
```

Expected output (only GPU + its audio):
```
=== 0000:03:00.0 ===
03:00.0 VGA compatible controller [0300]: NVIDIA Corporation GM204GL [Quadro M4000] [10de:13f1] (rev a1)
=== 0000:03:00.1 ===
03:00.1 Audio device [0403]: NVIDIA Corporation GM204 High Definition Audio Controller [10de:0fbb] (rev a1)
```

Verify VFIO driver is bound:
```bash
lspci -vvs 03:00 | grep "Kernel driver"
# Should show: Kernel driver in use: vfio-pci
```

**✅ Good**: Only GPU (03:00.0) and its HDMI audio (03:00.1) in the group
**❌ Bad**: Other devices like SATA controllers or USB hubs in the same group

### 3. Create PCI Resource Mapping (Proxmox 8+/9)

Proxmox 8+ requires PCI devices to be mapped before API tokens can use them.

**Via Proxmox Web UI** (recommended):
1. Go to **Datacenter → Resource Mappings → PCI Devices**
2. Click **Add**
3. Set ID: `gpu-quadro-m4000`
4. Click **Add Mapping**
5. Select Node: `server`
6. Select Device: `03:00.0` (Quadro M4000) from dropdown
7. Click **Create**

> **⚠️ Warning about IOMMU group**: Proxmox may show a warning:
> *"A selected device is not in a separate IOMMU group"*
>
> **This is OK to ignore** if your IOMMU group only contains the GPU and its
> audio device (as verified above). They are both part of the same physical
> GPU card and should be passed through together. The warning would only be
> a problem if unrelated devices (SATA, USB, etc.) were in the same group.

## Deployment

### 1. Apply Terraform

```bash
cd terraform

# Plan to see changes
terraform plan

# Apply to create the VM
terraform apply
```

### 2. Run Setup Script

After the VM is created:

```bash
cd bootstrap

# Make executable
chmod +x whisper-setup.sh

# Run setup (will prompt for reboot)
./whisper-setup.sh 192.168.20.30
```

The script will:
1. Install NVIDIA drivers (requires reboot)
2. Set up Python environment with faster-whisper
3. Download the large-v3-turbo model
4. Start the API service

### 3. Verify Installation

```bash
# Health check
curl http://192.168.20.30:8000/health

# Expected response:
# {
#   "status": "healthy",
#   "model": "deepdml/faster-whisper-large-v3-turbo-ct2",
#   "device": "cuda (Quadro M4000)",
#   "gpu_available": true
# }
```

## API Usage

### Transcribe Audio File

```bash
curl -X POST http://192.168.20.30:8000/transcribe \
  -F 'file=@audio.mp3'
```

Response:
```json
{
  "text": "Hello world, this is a test transcription.",
  "language": "en",
  "duration": 5.24,
  "processing_time": 1.82,
  "segments": null
}
```

### With Options

```bash
# Specify language and include timestamps
curl -X POST 'http://192.168.20.30:8000/transcribe?language=en&include_segments=true' \
  -F 'file=@audio.mp3'
```

### Transcribe from URL

```bash
curl -X POST http://192.168.20.30:8000/transcribe/url \
  -H "Content-Type: application/json" \
  -d '{"url": "https://example.com/audio.mp3"}'
```

### Translate to English

```bash
curl -X POST 'http://192.168.20.30:8000/transcribe?task=translate' \
  -F 'file=@spanish-audio.mp3'
```

## API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/health` | GET | Health check and GPU status |
| `/transcribe` | POST | Transcribe uploaded audio file |
| `/transcribe/url` | POST | Transcribe audio from URL |
| `/docs` | GET | Interactive API documentation (Swagger) |

## Query Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `language` | string | auto | Language code (e.g., 'en', 'es', 'de') |
| `include_segments` | bool | false | Include word-level timestamps |
| `task` | string | transcribe | 'transcribe' or 'translate' (to English) |

## Using from Werify App

In your Elixir/Phoenix app, call the Whisper API:

```elixir
defmodule Werify.Transcription do
  @whisper_url "http://192.168.20.30:8000"

  def transcribe(audio_path) do
    {:ok, audio_data} = File.read(audio_path)

    Req.post!("#{@whisper_url}/transcribe",
      form_multipart: [
        file: {audio_data, filename: Path.basename(audio_path)}
      ]
    ).body
  end
end
```

Or with HTTPoison:

```elixir
def transcribe(audio_path) do
  url = "http://192.168.20.30:8000/transcribe"

  {:ok, response} = HTTPoison.post(
    url,
    {:multipart, [
      {:file, audio_path, {"form-data", [name: "file", filename: Path.basename(audio_path)]}, []}
    ]},
    [],
    recv_timeout: 300_000  # 5 min timeout for long audio
  )

  Jason.decode!(response.body)
end
```

## Troubleshooting

### GPU Not Detected

```bash
# SSH into the VM
ssh deployer@192.168.20.30

# Check if GPU is visible
lspci | grep -i nvidia

# Check driver status
nvidia-smi

# Check kernel messages
dmesg | grep -i nvidia
```

### Service Issues

```bash
# Check service status
sudo systemctl status whisper-api

# View logs
sudo journalctl -u whisper-api -f

# Restart service
sudo systemctl restart whisper-api
```

### Model Loading Issues

```bash
# Check available disk space
df -h

# Check model download
ls -la /opt/whisper/models/

# Manually test model loading
cd /opt/whisper
source venv/bin/activate
python3 -c "from faster_whisper import WhisperModel; m = WhisperModel('deepdml/faster-whisper-large-v3-turbo-ct2', device='cuda')"
```

### Memory Issues

If you get CUDA out of memory errors:

```bash
# Edit the service to use int8 quantization
sudo systemctl edit whisper-api

# Add:
[Service]
Environment="WHISPER_COMPUTE_TYPE=int8"

# Restart
sudo systemctl restart whisper-api
```

## Performance

Expected performance with Quadro M4000 + large-v3-turbo:

| Audio Duration | Processing Time | Real-time Factor |
|----------------|-----------------|------------------|
| 1 minute | ~10-15 seconds | 4-6x |
| 5 minutes | ~45-60 seconds | 5-7x |
| 30 minutes | ~4-5 minutes | 6-7x |

The turbo model is ~4x faster than the standard large-v3 while maintaining similar accuracy.

## Security Notes

- The API has no authentication by default
- Only expose it on internal network (192.168.20.x)
- Do not expose port 8000 to the internet
- Consider adding API key authentication if needed
