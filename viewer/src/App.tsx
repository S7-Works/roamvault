import { createSignal, onMount, For, Show } from "solid-js";
import { createStore } from "solid-js/store";
import { useParams } from "@solidjs/router";
import "./App.css";

interface InitData {
  chatId: string;
  chatName: string;
  platform: string;
  messageCount: number;
}

interface MessageView {
  timestamp: string;
  sender: string;
  body: string | null;
  media_url: string | null;
}

interface MessageChunk {
  messages: MessageView[];
  chunk_index: number;
  total_chunks: number;
}

export default function App() {
  const params = useParams<{ id: string }>();

  const INIT: InitData = (window as any).__INIT__ ?? {
    chatId: params.id ?? "demo",
    chatName: "Chat",
    platform: "whatsapp",
    messageCount: 0,
  };
  const [messages, setMessages] = createSignal<MessageView[]>([]);
  const [chunk, setChunk] = createSignal(0);
  const [totalChunks, setTotalChunks] = createSignal(1);
  const [loading, setLoading] = createSignal(false);
  const [search, setSearch] = createSignal("");
  const [mediaUrls, setMediaUrls] = createStore<Record<string, string>>({});

  const senderColor = (sender: string) => {
    const colors = ["#0d6efd", "#198754", "#dc3545", "#fd7e14", "#6f42c1", "#20c997"];
    let hash = 0;
    for (const c of sender) hash = (hash * 31 + c.charCodeAt(0)) & 0xffff;
    return colors[hash % colors.length];
  };

  const loadChunk = async (idx: number) => {
    if (loading()) return;
    setLoading(true);
    try {
      const res = await fetch(`/api/chat/${INIT.chatId}/messages?chunk=${idx}`);
      const data: MessageChunk = await res.json();
      setMessages((prev) => (idx === 0 ? data.messages : [...prev, ...data.messages]));
      setChunk(idx);
      setTotalChunks(data.total_chunks);

      for (const msg of data.messages) {
        if (msg.media_url && !mediaUrls[msg.media_url]) {
          fetch(`/api/media/${msg.media_url}`)
            .then((r) => r.json())
            .then((d) => setMediaUrls(msg.media_url!, d.url));
        }
      }
    } finally {
      setLoading(false);
    }
  };

  onMount(() => loadChunk(0));

  const filtered = () => {
    const q = search().toLowerCase();
    if (!q) return messages();
    return messages().filter((m) => m.body?.toLowerCase().includes(q));
  };

  const formatTime = (ts: string) =>
    new Date(ts).toLocaleString(undefined, {
      month: "short",
      day: "numeric",
      hour: "2-digit",
      minute: "2-digit",
    });

  return (
    <div class="app">
      <header class="chat-header">
        <div class="header-info">
          <h1>{INIT.chatName}</h1>
          <span class="meta">{INIT.messageCount.toLocaleString()} messages · {INIT.platform}</span>
        </div>
        <input
          class="search"
          type="search"
          placeholder="Search messages…"
          value={search()}
          onInput={(e) => setSearch(e.currentTarget.value)}
        />
      </header>

      <div class="chat-window">
        <For each={filtered()}>
          {(msg) => (
            <div class="message">
              <div class="message-meta">
                <span class="sender" style={{ color: senderColor(msg.sender) }}>
                  {msg.sender}
                </span>
                <span class="time">{formatTime(msg.timestamp)}</span>
              </div>
              <div class="bubble">
                <Show when={msg.body}>
                  <p>{msg.body}</p>
                </Show>
                <Show when={msg.media_url}>
                  <MediaItem hash={msg.media_url!} url={mediaUrls[msg.media_url!]} />
                </Show>
              </div>
            </div>
          )}
        </For>

        <Show when={chunk() + 1 < totalChunks()}>
          <button class="load-more" onClick={() => loadChunk(chunk() + 1)} disabled={loading()}>
            {loading() ? "Loading…" : "Load more"}
          </button>
        </Show>
      </div>
    </div>
  );
}

function MediaItem(props: { hash: string; url: string | undefined }) {
  if (!props.url) return <div class="media-placeholder">Loading media…</div>;

  const ext = props.url.split("?")[0].split(".").pop()?.toLowerCase() ?? "";

  if (["jpg", "jpeg", "png", "webp"].includes(ext)) {
    return <img src={props.url} class="media-img" loading="lazy" />;
  }
  if (["mp4", "mov"].includes(ext)) {
    return <video src={props.url} class="media-video" controls />;
  }
  if (["ogg", "opus", "aac"].includes(ext)) {
    return <audio src={props.url} controls />;
  }
  return <a href={props.url} target="_blank" rel="noopener">Download attachment</a>;
}
