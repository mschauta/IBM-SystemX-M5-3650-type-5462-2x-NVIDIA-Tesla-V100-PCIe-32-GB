# Tools

## Copy-OllamaModel.ps1

Copies Ollama models from one models directory to another: the manifest plus all referenced blobs. For example, from a network share to a local NVMe disk. The source is only read. Blobs that already exist at the target with the same size are skipped.

```powershell
.\Copy-OllamaModel.ps1 -Source '\\nas\share\Ollama\models' -Dest 'D:\ollama_models' -Models 'llama3.3:70b','deepseek-r1:70b'
```

Then point a server at the copy, either with `OLLAMA_MODELS=D:\ollama_models` or with `ollama_benchmark.ps1 -ModelsDir D:\ollama_models`.

Why: a 43 GB model loads in about 7 minutes from a 1 GbE share, which exceeds Ollama's default 5-minute load timeout. From NVMe it loads in 37 s.
