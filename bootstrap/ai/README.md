# AI Services GPU Inference Server

GPU-accelerated AI services running on a single VM with GPU time-sharing:
- **Whisper** - Speech-to-text transcription using [faster-whisper](https://github.com/SYSTRAN/faster-whisper) with `large-v3-turbo`
- **Ollama** - LLM inference for text generation, translation, etc. using [Qwen 2.5](https://ollama.com/library/qwen2.5) or any other model

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                      ai.internal.example.com                     │
├─────────────────────────────────────────────────────────────────┤
│                           nginx (443)                            │
│  ┌──────────────┬──────────────────┬─────────────────────────┐  │
│  │ /transcribe  │    /generate     │  /v1/chat/completions   │  │
│  │      ↓       │        ↓         │          ↓              │  │
│  │ whisper-api  │     ollama       │       ollama            │  │
│  │   :8000      │     :11434       │       :11434            │  │
│  └──────────────┴──────────────────┴─────────────────────────┘  │
│                                                                  │
│                    GPU: Quadro M4000 (8GB)                       │
│                    (time-shared between services)                │
└─────────────────────────────────────────────────────────────────┘
```

## GPU Time-Sharing

Both Whisper and Ollama share the same GPU. They can coexist because:

1. **Ollama auto-unloads models** - After 5 minutes of inactivity, the model is unloaded from VRAM
2. **Sequential processing** - Requests are processed one at a time
3. **Memory footprint**:
   - Whisper turbo: ~2-3GB VRAM when processing
   - Qwen 2.5 3B: ~6GB VRAM when loaded

When you use transcription, Ollama's model may be unloaded. When you use Ollama, the model reloads (takes ~5-10 seconds first time).

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/health` | GET | Health check (Whisper status) |
| `/transcribe` | POST | Transcribe audio file |
| `/transcribe/url` | POST | Transcribe audio from URL |
| `/generate` | POST | Ollama generate (custom prompts) |
| `/v1/chat/completions` | POST | OpenAI-compatible chat API |
| `/api/*` | * | Full Ollama API |
| `/docs` | GET | Swagger API documentation (Whisper) |
| `/queue/status` | GET | Whisper queue status |

## API Usage

### Transcribe Audio

```bash
# Upload audio file
curl -X POST https://ai.internal.example.com/transcribe \
  -F 'file=@audio.mp3'

# Response
{
  "text": "Hello world, this is a test transcription.",
  "language": "en",
  "duration": 5.24,
  "processing_time": 1.82
}
```

### Generate Text (Translation Example)

```bash
# Using /generate endpoint
curl -X POST https://ai.internal.example.com/generate \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "qwen2.5:3b",
    "prompt": "Translate the following English text to Brazilian Portuguese. Only output the translation:\n\nHello, how are you today?",
    "stream": false
  }'

# Response
{
  "model": "qwen2.5:3b",
  "response": "Olá, como você está hoje?",
  "done": true
}
```

### OpenAI-Compatible Chat

```bash
curl -X POST https://ai.internal.example.com/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "qwen2.5:3b",
    "messages": [
      {"role": "system", "content": "You are a translator. Translate user messages from English to Brazilian Portuguese. Only output the translation."},
      {"role": "user", "content": "Hello, how are you today?"}
    ]
  }'

# Response
{
  "choices": [{
    "message": {
      "role": "assistant",
      "content": "Olá, como você está hoje?"
    }
  }]
}
```

### Other Ollama Operations

```bash
# List available models
curl https://ai.internal.example.com/api/tags

# Pull a new model
curl -X POST https://ai.internal.example.com/api/pull \
  -d '{"name": "qwen2.5:1.5b"}'

# Delete a model
curl -X DELETE https://ai.internal.example.com/api/delete \
  -d '{"name": "qwen2.5:1.5b"}'
```

## Deployment

### Fresh Deployment (Terraform)

```bash
cd terraform

# Set required variables in terraform.tfvars or via environment
export TF_VAR_ai_domain="ai.internal.example.com"
export TF_VAR_ai_github_owner="your-username"
export TF_VAR_ai_ghcr_token="ghp_xxxx"

# Plan and apply
terraform plan
terraform apply
```

### Migrate Existing Whisper VM

```bash
cd bootstrap/ai

# Make executable
chmod +x migrate-to-ai-services.sh

# Run migration
./migrate-to-ai-services.sh 192.168.20.30 your-username ghp_xxxx ai.internal.example.com
```

The migration script will:
1. Add Ollama to docker-compose
2. Update nginx configuration
3. Obtain new SSL certificate
4. Pull the Qwen model

## Configuration

### Terraform Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `ai_domain` | Domain for AI services | `ai.internal.prakash.com.br` |
| `ai_github_owner` | GitHub owner for whisper-api image | - |
| `ai_ghcr_token` | GitHub PAT with `packages:read` | - |
| `ai_ollama_model` | Ollama model to pre-pull | `qwen2.5:3b` |

### Environment Variables

When running the migration script:

| Variable | Description | Default |
|----------|-------------|---------|
| `OLLAMA_MODEL` | Model to pull on setup | `qwen2.5:3b` |
| `SSH_USER` | SSH username | `deployer` |
| `SSH_KEY` | Path to SSH private key | - |

### Ollama Model Options

You can use any model from the [Ollama library](https://ollama.com/library). For translation:

| Model | VRAM | Quality | Speed |
|-------|------|---------|-------|
| `qwen2.5:1.5b` | ~3GB | Good | Fast |
| `qwen2.5:3b` | ~6GB | Better | Medium |
| `qwen2.5:7b` | ~14GB | Best | Slow (won't fit with Whisper) |

To add more models after deployment:

```bash
ssh deployer@192.168.20.30

# Pull additional models
docker exec ollama ollama pull llama3.2:3b
docker exec ollama ollama pull mistral:7b

# List models
docker exec ollama ollama list
```

## Using from Applications

### Elixir/Phoenix

```elixir
defmodule MyApp.AI do
  @ai_url "https://ai.internal.example.com"

  def transcribe(audio_path) do
    {:ok, audio_data} = File.read(audio_path)

    Req.post!("#{@ai_url}/transcribe",
      form_multipart: [file: {audio_data, filename: Path.basename(audio_path)}]
    ).body
  end

  def generate(prompt, model \\ "qwen2.5:3b") do
    Req.post!("#{@ai_url}/generate",
      json: %{model: model, prompt: prompt, stream: false}
    ).body["response"]
  end

  def translate(text, from \\ "English", to \\ "Brazilian Portuguese") do
    prompt = """
    Translate the following #{from} text to #{to}. Only output the translation:

    #{text}
    """
    generate(prompt)
  end
end

# Usage
MyApp.AI.transcribe("/path/to/audio.mp3")
MyApp.AI.translate("Hello world")
MyApp.AI.generate("Write a haiku about coding")
```

### Python

```python
import requests

AI_URL = "https://ai.internal.example.com"

def transcribe(audio_path: str) -> dict:
    with open(audio_path, "rb") as f:
        response = requests.post(f"{AI_URL}/transcribe", files={"file": f})
    return response.json()

def generate(prompt: str, model: str = "qwen2.5:3b") -> str:
    response = requests.post(
        f"{AI_URL}/generate",
        json={"model": model, "prompt": prompt, "stream": False}
    )
    return response.json()["response"]

def translate(text: str, source="English", target="Brazilian Portuguese") -> str:
    prompt = f"Translate the following {source} text to {target}. Only output the translation:\n\n{text}"
    return generate(prompt)

# Usage
result = transcribe("audio.mp3")
print(result["text"])

translated = translate("Hello, how are you?")
print(translated)  # "Olá, como você está?"
```

### JavaScript/TypeScript

```typescript
const AI_URL = "https://ai.internal.example.com";

async function transcribe(audioFile: File): Promise<TranscriptionResult> {
  const formData = new FormData();
  formData.append("file", audioFile);

  const response = await fetch(`${AI_URL}/transcribe`, {
    method: "POST",
    body: formData,
  });
  return response.json();
}

async function generate(prompt: string, model = "qwen2.5:3b"): Promise<string> {
  const response = await fetch(`${AI_URL}/generate`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ model, prompt, stream: false }),
  });
  const result = await response.json();
  return result.response;
}

async function translate(text: string, from = "English", to = "Brazilian Portuguese"): Promise<string> {
  const prompt = `Translate the following ${from} text to ${to}. Only output the translation:\n\n${text}`;
  return generate(prompt);
}
```

## Troubleshooting

### Check Service Status

```bash
ssh deployer@192.168.20.30

# Check all containers
cd /opt/ai && docker compose ps

# Check logs
docker compose logs -f whisper-api
docker compose logs -f ollama
```

### GPU Issues

```bash
# Check GPU is visible
nvidia-smi

# Check GPU memory usage
watch -n 1 nvidia-smi

# Verify NVIDIA Container Toolkit
nvidia-ctk --version
```

### Ollama Model Not Loading

```bash
# Check if model is downloaded
docker exec ollama ollama list

# Pull model manually
docker exec ollama ollama pull qwen2.5:3b

# Check Ollama logs
docker logs ollama -f
```

### Slow First Response

The first request after idle will be slow because:
1. Ollama needs to load the model into VRAM (~5-10 seconds)

To pre-warm the model:

```bash
curl -X POST https://ai.internal.example.com/generate \
  -d '{"model": "qwen2.5:3b", "prompt": "Hi", "stream": false}'
```

### SSL Certificate Issues

```bash
# Check certificate
sudo certbot certificates

# Renew certificate
sudo certbot renew --dry-run

# Force renewal
sudo certbot certonly --dns-cloudflare \
  --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
  -d ai.internal.example.com --force-renewal
```

## Performance

### Transcription (Whisper)

| Audio Duration | Processing Time | Real-time Factor |
|----------------|-----------------|------------------|
| 1 minute | ~10-15 seconds | 4-6x |
| 5 minutes | ~45-60 seconds | 5-7x |
| 30 minutes | ~4-5 minutes | 6-7x |

### Text Generation (Qwen 2.5 3B)

| Text Length | First Request | Subsequent |
|-------------|---------------|------------|
| Short (~50 tokens) | 5-10s | 1-2s |
| Medium (~200 tokens) | 10-15s | 3-5s |
| Long (~500 tokens) | 15-25s | 5-10s |

*First request is slower because the model needs to load into VRAM.*

## Security Notes

- The API has no authentication by default
- Only expose it on internal network (192.168.20.x)
- Do not expose to the internet without adding authentication
- Consider adding API key authentication if needed
