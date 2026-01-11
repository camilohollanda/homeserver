#!/usr/bin/env python3
"""
Whisper Transcription API
Using OpenAI's official Whisper - works with Maxwell GPUs.
"""
import os
import tempfile
import time
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, File, UploadFile, HTTPException, Query
from pydantic import BaseModel
import uvicorn
import torch

app = FastAPI(
    title="Whisper Transcription API",
    description="GPU-accelerated speech-to-text using OpenAI Whisper",
    version="2.0.0"
)

MODEL_NAME = os.getenv("WHISPER_MODEL", "turbo")
DEVICE = os.getenv("WHISPER_DEVICE", "cuda" if torch.cuda.is_available() else "cpu")

_model = None

def get_model():
    global _model
    if _model is None:
        import whisper
        print(f"Loading Whisper model: {MODEL_NAME} on {DEVICE}")
        _model = whisper.load_model(MODEL_NAME, device=DEVICE)
        print("Model loaded successfully!")
    return _model

class TranscriptionResponse(BaseModel):
    text: str
    language: str
    duration: Optional[float] = None
    processing_time: float
    segments: Optional[list] = None

class HealthResponse(BaseModel):
    status: str
    model: str
    device: str
    gpu_available: bool
    gpu_name: Optional[str] = None

@app.get("/health", response_model=HealthResponse)
async def health_check():
    gpu_available = torch.cuda.is_available()
    gpu_name = torch.cuda.get_device_name(0) if gpu_available else None
    return HealthResponse(
        status="healthy",
        model=MODEL_NAME,
        device=DEVICE,
        gpu_available=gpu_available,
        gpu_name=gpu_name
    )

@app.post("/transcribe", response_model=TranscriptionResponse)
async def transcribe(
    file: UploadFile = File(...),
    language: Optional[str] = Query("pt", description="Language code (e.g., 'pt', 'en')"),
    include_segments: bool = Query(False),
    task: str = Query("transcribe"),
    temperature: float = Query(0.0, description="Sampling temperature (0 = deterministic)"),
    best_of: int = Query(5, description="Number of candidates for beam search")
):
    start_time = time.time()
    allowed_extensions = {".mp3", ".wav", ".m4a", ".ogg", ".flac", ".webm", ".mp4", ".opus"}
    file_ext = Path(file.filename).suffix.lower() if file.filename else ""

    if file_ext not in allowed_extensions:
        raise HTTPException(status_code=400, detail=f"Unsupported: {file_ext}")

    with tempfile.NamedTemporaryFile(delete=False, suffix=file_ext) as tmp:
        content = await file.read()
        tmp.write(content)
        tmp_path = tmp.name

    try:
        model = get_model()
        options = {
            "task": task,
            "language": language,
            "temperature": temperature,
            "best_of": best_of
        }

        result = model.transcribe(tmp_path, **options)

        segments_list = None
        if include_segments and "segments" in result:
            segments_list = [
                {"start": round(s["start"], 2), "end": round(s["end"], 2), "text": s["text"].strip()}
                for s in result["segments"]
            ]

        return TranscriptionResponse(
            text=result["text"].strip(),
            language=result.get("language", "unknown"),
            processing_time=round(time.time() - start_time, 2),
            segments=segments_list
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        os.unlink(tmp_path)

@app.post("/transcribe/batch")
async def transcribe_batch(
    files: list[UploadFile] = File(...),
    language: Optional[str] = Query("pt", description="Language code (e.g., 'pt', 'en')"),
    include_segments: bool = Query(False),
    task: str = Query("transcribe"),
    temperature: float = Query(0.0, description="Sampling temperature (0 = deterministic)"),
    best_of: int = Query(5, description="Number of candidates for beam search")
):
    """Transcribe multiple audio files in a single request."""
    start_time = time.time()
    allowed_extensions = {".mp3", ".wav", ".m4a", ".ogg", ".flac", ".webm", ".mp4", ".opus"}
    model = get_model()

    results = []
    for file in files:
        file_start = time.time()
        file_ext = Path(file.filename).suffix.lower() if file.filename else ""

        if file_ext not in allowed_extensions:
            results.append({
                "filename": file.filename,
                "error": f"Unsupported file type: {file_ext}"
            })
            continue

        with tempfile.NamedTemporaryFile(delete=False, suffix=file_ext) as tmp:
            content = await file.read()
            tmp.write(content)
            tmp_path = tmp.name

        try:
            options = {
                "task": task,
                "language": language,
                "temperature": temperature,
                "best_of": best_of
            }

            result = model.transcribe(tmp_path, **options)

            segments_list = None
            if include_segments and "segments" in result:
                segments_list = [
                    {"start": round(s["start"], 2), "end": round(s["end"], 2), "text": s["text"].strip()}
                    for s in result["segments"]
                ]

            results.append({
                "filename": file.filename,
                "text": result["text"].strip(),
                "language": result.get("language", "unknown"),
                "processing_time": round(time.time() - file_start, 2),
                "segments": segments_list
            })
        except Exception as e:
            results.append({
                "filename": file.filename,
                "error": str(e)
            })
        finally:
            os.unlink(tmp_path)

    return {
        "total_files": len(files),
        "total_processing_time": round(time.time() - start_time, 2),
        "results": results
    }

if __name__ == "__main__":
    print("Pre-loading Whisper model...")
    get_model()
    print("Starting API server...")
    uvicorn.run(app, host="0.0.0.0", port=8000)
