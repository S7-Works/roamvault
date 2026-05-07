import { createSignal, Show } from "solid-js";
import "./Upload.css";

function getUserId(): string {
  const key = "roamvault_user_id";
  let id = localStorage.getItem(key);
  if (!id) {
    id = crypto.randomUUID();
    localStorage.setItem(key, id);
  }
  return id;
}

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

export default function Upload() {
  const [file, setFile] = createSignal<File | null>(null);
  const [dragOver, setDragOver] = createSignal(false);
  const [uploading, setUploading] = createSignal(false);
  const [progress, setProgress] = createSignal(0);
  const [error, setError] = createSignal<string | null>(null);
  const [viewId, setViewId] = createSignal<string | null>(null);
  const [copied, setCopied] = createSignal(false);

  let fileInput!: HTMLInputElement;

  const pickFile = (f: File) => {
    if (!f.name.endsWith(".zip")) {
      setError("Please select a .zip file.");
      return;
    }
    setFile(f);
    setError(null);
  };

  const onDrop = (e: DragEvent) => {
    e.preventDefault();
    setDragOver(false);
    const f = e.dataTransfer?.files[0];
    if (f) pickFile(f);
  };

  const onInputChange = (e: Event) => {
    const input = e.currentTarget as HTMLInputElement;
    const f = input.files?.[0];
    if (f) pickFile(f);
  };

  const upload = () => {
    const f = file();
    if (!f || uploading()) return;

    setUploading(true);
    setProgress(0);
    setError(null);

    const formData = new FormData();
    formData.append("file", f);
    formData.append("user_id", getUserId());

    const xhr = new XMLHttpRequest();

    xhr.upload.addEventListener("progress", (e) => {
      if (e.lengthComputable) {
        setProgress(Math.round((e.loaded / e.total) * 100));
      }
    });

    xhr.addEventListener("load", () => {
      setUploading(false);
      if (xhr.status >= 200 && xhr.status < 300) {
        try {
          const data = JSON.parse(xhr.responseText);
          setViewId(data.chat_id ?? data.id ?? data.chatId ?? null);
          if (!viewId()) {
            setError("Upload succeeded but no chat ID was returned.");
          }
        } catch {
          setError("Upload succeeded but the server response was unreadable.");
        }
      } else {
        let msg = `Upload failed (HTTP ${xhr.status})`;
        try {
          const data = JSON.parse(xhr.responseText);
          if (data.error || data.message) msg = data.error ?? data.message;
        } catch {}
        setError(msg);
      }
    });

    xhr.addEventListener("error", () => {
      setUploading(false);
      setError("Network error — check your connection and try again.");
    });

    xhr.addEventListener("abort", () => {
      setUploading(false);
      setError("Upload was cancelled.");
    });

    xhr.open("POST", "/upload/whatsapp");
    xhr.send(formData);
  };

  const viewUrl = () => {
    const id = viewId();
    return id ? `${window.location.origin}/view/${id}` : "";
  };

  const copyLink = async () => {
    try {
      await navigator.clipboard.writeText(viewUrl());
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch {
      // fallback: select the link text
    }
  };

  const reset = () => {
    setFile(null);
    setViewId(null);
    setError(null);
    setProgress(0);
    fileInput.value = "";
  };

  return (
    <div class="upload-page">
      <div class="upload-card">
        <Show when={!viewId()}>
          <h1>RoamVault</h1>
          <p class="subtitle">Upload your WhatsApp chat export to view it privately in your browser.</p>

          {/* Drop zone */}
          <div
            class={`drop-zone${dragOver() ? " drag-over" : ""}`}
            onDragOver={(e) => { e.preventDefault(); setDragOver(true); }}
            onDragLeave={() => setDragOver(false)}
            onDrop={onDrop}
            onClick={() => fileInput.click()}
          >
            <span class="drop-icon">📦</span>
            <span class="drop-label">
              Drag &amp; drop your <strong>.zip</strong> here, or{" "}
              <span class="browse-link">browse</span>
            </span>
            <span class="drop-hint">WhatsApp export zip only</span>
          </div>

          <input
            ref={fileInput}
            type="file"
            accept=".zip"
            style={{ display: "none" }}
            onChange={onInputChange}
          />

          {/* Selected file info */}
          <Show when={file()}>
            <div class="file-info">
              <span class="file-icon">🗜️</span>
              <div class="file-details">
                <span class="file-name">{file()!.name}</span>
                <span class="file-size">{formatBytes(file()!.size)}</span>
              </div>
              <button class="clear-btn" title="Remove" onClick={(e) => { e.stopPropagation(); reset(); }}>✕</button>
            </div>
          </Show>

          {/* Progress bar */}
          <Show when={uploading()}>
            <div class="progress-wrap">
              <div class="progress-bar-track">
                <div class="progress-bar-fill" style={{ width: `${progress()}%` }} />
              </div>
              <span class="progress-label">{progress()}%</span>
            </div>
          </Show>

          {/* Error */}
          <Show when={error()}>
            <div class="error-msg">{error()}</div>
          </Show>

          {/* Upload button */}
          <button
            class="upload-btn"
            disabled={!file() || uploading()}
            onClick={upload}
          >
            {uploading() ? "Uploading…" : "Upload"}
          </button>
        </Show>

        {/* Success state */}
        <Show when={viewId()}>
          <div class="success-box">
            <span class="success-icon">✅</span>
            <h2>Upload complete!</h2>
            <p>Your chat is ready to view. Share the link below or open it now.</p>

            <div class="view-link-row">
              <a href={viewUrl()} target="_blank" rel="noopener">{viewUrl()}</a>
              <button
                class={`copy-btn${copied() ? " copied" : ""}`}
                onClick={copyLink}
              >
                {copied() ? "Copied!" : "Copy"}
              </button>
            </div>

            <a href={viewUrl()} target="_blank" rel="noopener">
              <button class="upload-btn" style={{ width: "100%" }}>Open chat →</button>
            </a>

            <button class="upload-another-btn" onClick={reset}>
              Upload another chat
            </button>
          </div>
        </Show>
      </div>
    </div>
  );
}
