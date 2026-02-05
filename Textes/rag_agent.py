import argparse
import json
import re
import sys
from pathlib import Path
from typing import Dict, List, Tuple
from urllib.parse import urlparse, parse_qs

import numpy as np
import requests
from bs4 import BeautifulSoup
from pypdf import PdfReader

import config


def get_base_url_from_confluence(confluence_url: str) -> str:
    parsed = urlparse(confluence_url)
    return f"{parsed.scheme}://{parsed.netloc}"


def extract_page_id(confluence_url: str) -> str:
    # Supports URLs like .../pages/80904221/... or ?pageId=80904221
    match = re.search(r"/pages/(\d+)", confluence_url)
    if match:
        return match.group(1)
    parsed = urlparse(confluence_url)
    qs = parse_qs(parsed.query)
    if "pageId" in qs:
        return qs["pageId"][0]
    raise ValueError("Unable to extract Confluence page ID from URL")


def confluence_get_page(base: str, page_id: str, auth: Tuple[str, str]) -> Dict:
    url = f"{base}/rest/api/content/{page_id}"
    params = {"expand": "body.storage"}
    resp = requests.get(url, params=params, auth=auth, timeout=30)
    resp.raise_for_status()
    return resp.json()


def confluence_list_children(base: str, page_id: str, auth: Tuple[str, str]) -> List[Dict]:
    children = []
    start = 0
    limit = 50
    while True:
        url = f"{base}/rest/api/content/{page_id}/child/page"
        params = {"limit": limit, "start": start}
        resp = requests.get(url, params=params, auth=auth, timeout=30)
        resp.raise_for_status()
        data = resp.json()
        children.extend(data.get("results", []))
        if start + limit >= data.get("size", 0):
            break
        start += limit
    return children


def html_to_text(html: str) -> str:
    soup = BeautifulSoup(html, "html.parser")
    # Remove scripts/styles
    for tag in soup(["script", "style"]):
        tag.decompose()
    text = soup.get_text("\n")
    # Normalize whitespace
    lines = [line.strip() for line in text.splitlines()]
    return "\n".join([line for line in lines if line])


def fetch_confluence_tree(confluence_url: str, max_pages: int) -> List[Dict]:
    base = get_base_url_from_confluence(confluence_url)
    page_id = extract_page_id(confluence_url)
    auth = (config.CONFLUENCE_USER, config.CONFLUENCE_PASSWORD)

    queue = [page_id]
    seen = set()
    pages = []

    while queue and len(pages) < max_pages:
        pid = queue.pop(0)
        if pid in seen:
            continue
        seen.add(pid)

        try:
            page = confluence_get_page(base, pid, auth)
            title = page.get("title", "")
            body_html = page.get("body", {}).get("storage", {}).get("value", "")
            text = html_to_text(body_html)
            pages.append({"id": pid, "title": title, "text": text})

            children = confluence_list_children(base, pid, auth)
            for child in children:
                cid = child.get("id")
                if cid and cid not in seen:
                    queue.append(cid)
        except requests.HTTPError as e:
            print(f"[warn] Confluence REST failed for page {pid}: {e}", file=sys.stderr)
            break

    return pages


def fetch_pdf_pages(pdf_path: str) -> List[Dict]:
    path = Path(pdf_path)
    if not path.exists():
        raise FileNotFoundError(f"PDF not found: {pdf_path}")
    if not path.is_file():
        raise FileNotFoundError(f"PDF path is not a file: {pdf_path}")

    reader = PdfReader(str(path))
    print(f"[info] PDF loaded: {path.name}, pages: {len(reader.pages)}")
    pages = []
    for i, page in enumerate(reader.pages, start=1):
        if i % 10 == 1 or i == len(reader.pages):
            print(f"[info] extracting text: page {i}/{len(reader.pages)}")
        text = page.extract_text() or ""
        pages.append({
            "id": f"{path.name}#p{i}",
            "title": f"{path.name} - page {i}",
            "text": text.strip(),
        })
    return pages


def chunk_text(text: str, chunk_size_words: int, overlap_words: int) -> List[str]:
    words = text.split()
    if not words:
        return []
    chunks = []
    start = 0
    while start < len(words):
        end = min(start + chunk_size_words, len(words))
        chunk = " ".join(words[start:end])
        chunks.append(chunk)
        if end == len(words):
            break
        start = max(0, end - overlap_words)
    return chunks


def list_models(base_url: str) -> List[str]:
    resp = requests.get(f"{base_url}/models", timeout=30)
    resp.raise_for_status()
    data = resp.json()
    models = [m.get("id") for m in data.get("data", []) if m.get("id")]
    return models


def embed_texts(base_url: str, model: str, texts: List[str]) -> List[List[float]]:
    resp = requests.post(
        f"{base_url}/embeddings",
        json={"model": model, "input": texts},
        timeout=config.EMBED_TIMEOUT_SEC,
    )
    resp.raise_for_status()
    data = resp.json()
    # OpenAI-compatible: data.data is list with index + embedding
    vectors = [item["embedding"] for item in sorted(data["data"], key=lambda x: x["index"])]
    return vectors


def chat_completion(base_url: str, model: str, messages: List[Dict], temperature: float) -> str:
    resp = requests.post(
        f"{base_url}/chat/completions",
        json={
            "model": model,
            "messages": messages,
            "temperature": temperature,
        },
        timeout=config.LLM_TIMEOUT_SEC,
    )
    resp.raise_for_status()
    data = resp.json()
    return data["choices"][0]["message"]["content"].strip()


def build_index(pages: List[Dict], model: str) -> Dict:
    records = []
    batch = []
    meta = []
    total_pages = len(pages)
    print(f"[info] building index from {total_pages} pages")

    for p_idx, page in enumerate(pages, start=1):
        chunks = chunk_text(page["text"], config.CHUNK_SIZE_WORDS, config.CHUNK_OVERLAP_WORDS)
        if p_idx % 10 == 1 or p_idx == total_pages:
            print(f"[info] page {p_idx}/{total_pages}: {len(chunks)} chunks")
        for i, chunk in enumerate(chunks):
            batch.append(chunk)
            meta.append({
                "page_id": page["id"],
                "title": page["title"],
                "chunk_index": i,
                "text": chunk,
            })
            if len(batch) >= config.BATCH_SIZE:
                print(f"[info] embedding batch of {len(batch)} chunks")
                vectors = embed_texts(config.BASE_URL, model, batch)
                for m, v in zip(meta, vectors):
                    records.append({**m, "embedding": v})
                batch = []
                meta = []

    if batch:
        print(f"[info] embedding final batch of {len(batch)} chunks")
        vectors = embed_texts(config.BASE_URL, model, batch)
        for m, v in zip(meta, vectors):
            records.append({**m, "embedding": v})

    return {
        "model": model,
        "count": len(records),
        "records": records,
    }


def save_index(index: Dict, path: str) -> None:
    with open(path, "w", encoding="utf-8") as f:
        json.dump(index, f, ensure_ascii=False)


def load_index(path: str) -> Dict:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def cosine_similarity(a: np.ndarray, b: np.ndarray) -> float:
    if a.ndim == 1:
        a = a[None, :]
    if b.ndim == 1:
        b = b[None, :]
    a_norm = a / (np.linalg.norm(a, axis=1, keepdims=True) + 1e-12)
    b_norm = b / (np.linalg.norm(b, axis=1, keepdims=True) + 1e-12)
    return (a_norm @ b_norm.T).squeeze()


def search(index: Dict, query: str, top_k: int) -> List[Dict]:
    model = index.get("model")
    q_vec = embed_texts(config.BASE_URL, model, [query])[0]
    q = np.array(q_vec, dtype=np.float32)

    embs = np.array([r["embedding"] for r in index["records"]], dtype=np.float32)
    scores = cosine_similarity(embs, q)
    top_idx = np.argsort(-scores)[:top_k]

    results = []
    for i in top_idx:
        r = index["records"][int(i)]
        results.append({
            "score": float(scores[int(i)]),
            "title": r["title"],
            "page_id": r["page_id"],
            "chunk_index": r["chunk_index"],
            "text": r["text"],
        })
    return results


def build_rag_messages(question: str, chunks: List[Dict], max_chars: int) -> List[Dict]:
    context_parts = []
    for i, c in enumerate(chunks, start=1):
        context_parts.append(f"[{i}] {c['title']}\n{c['text']}")
    context = "\n\n".join(context_parts)
    if max_chars > 0 and len(context) > max_chars:
        context = context[:max_chars]
    return [
        {
            "role": "system",
            "content": (
                "You are a careful assistant. Answer using only the provided context. "
                "If the answer is not in the context, say you could not find it."
            ),
        },
        {
            "role": "user",
            "content": f"Question:\n{question}\n\nContext:\n{context}",
        },
    ]


def build_plain_messages(question: str) -> List[Dict]:
    return [
        {
            "role": "system",
            "content": "You are a helpful assistant. Answer concisely and clearly.",
        },
        {
            "role": "user",
            "content": question,
        },
    ]


def compare_answers_with_llm(
    question: str,
    chunks: List[Dict],
    rag_answer: str,
    plain_answer: str,
    base_url: str,
    model: str,
    temperature: float,
) -> str:
    context_parts = []
    for i, c in enumerate(chunks, start=1):
        context_parts.append(f"[{i}] {c['title']}\n{c['text']}")
    context = "\n\n".join(context_parts)
    messages = [
        {
            "role": "system",
            "content": (
                "You compare two answers to the same question. "
                "Decide where RAG helped (grounded in context) and where it did not. "
                "Be specific and mention if either answer contains information not supported by context."
            ),
        },
        {
            "role": "user",
            "content": (
                f"Question:\n{question}\n\n"
                f"Context:\n{context}\n\n"
                f"Answer without RAG:\n{plain_answer}\n\n"
                f"Answer with RAG:\n{rag_answer}\n\n"
                "Provide a short conclusion in Russian."
            ),
        },
    ]
    return chat_completion(base_url, model, messages, temperature)


def cmd_list_models(_args: argparse.Namespace) -> None:
    models = list_models(config.BASE_URL)
    for m in models:
        print(m)


def cmd_index(args: argparse.Namespace) -> None:
    models = list_models(config.BASE_URL)
    model = args.model or (models[0] if models else None)
    if not model:
        raise RuntimeError("No models available on server")

    pages = fetch_confluence_tree(config.CONFLUENCE_URL, config.MAX_PAGES)
    index = build_index(pages, model)
    save_index(index, config.INDEX_PATH)
    print(f"Indexed {index['count']} chunks using model '{model}'")


def cmd_index_pdf(args: argparse.Namespace) -> None:
    models = list_models(config.BASE_URL)
    model = args.model or (models[0] if models else None)
    if not model:
        raise RuntimeError("No models available on server")

    pages = fetch_pdf_pages(args.pdf)
    index = build_index(pages, model)
    save_index(index, config.INDEX_PATH)
    print(f"Indexed {index['count']} chunks from PDF '{args.pdf}' using model '{model}'")


def cmd_search(args: argparse.Namespace) -> None:
    index = load_index(config.INDEX_PATH)
    results = search(index, args.query, args.top_k)
    for r in results:
        print(f"[{r['score']:.4f}] {r['title']} (page {r['page_id']}, chunk {r['chunk_index']})")
        print(r["text"])
        print("-")


def cmd_compare(args: argparse.Namespace) -> None:
    index = load_index(config.INDEX_PATH)
    chunks = search(index, args.query, args.top_k)

    llm_model = args.model or config.LLM_MODEL
    if not llm_model:
        raise RuntimeError("Set LLM_MODEL in config.py or pass --model")

    rag_messages = build_rag_messages(args.query, chunks, args.max_chars)
    plain_messages = build_plain_messages(args.query)

    print("[info] generating answer without RAG")
    plain_answer = chat_completion(config.BASE_URL, llm_model, plain_messages, config.LLM_TEMPERATURE)
    print("[info] generating answer with RAG")
    rag_answer = chat_completion(config.BASE_URL, llm_model, rag_messages, config.LLM_TEMPERATURE)

    print("\n=== Answer without RAG ===")
    print(plain_answer)
    print("\n=== Answer with RAG ===")
    print(rag_answer)

    print("\n=== Conclusion ===")
    conclusion = compare_answers_with_llm(
        args.query,
        chunks,
        rag_answer,
        plain_answer,
        config.BASE_URL,
        llm_model,
        config.LLM_TEMPERATURE,
    )
    print(conclusion)


def cmd_chat_rag(args: argparse.Namespace) -> None:
    index = load_index(config.INDEX_PATH)
    llm_model = args.model or config.LLM_MODEL
    if not llm_model:
        raise RuntimeError("Set LLM_MODEL in config.py or pass --model")

    print("[info] RAG chat ready. Type your question. Use 'exit' to quit.")
    while True:
        try:
            question = input("> ").strip()
        except EOFError:
            print()
            break
        if not question:
            continue
        if question.lower() in {"exit", "quit"}:
            break

        chunks = search(index, question, args.top_k)
        messages = build_rag_messages(question, chunks, args.max_chars)
        answer = chat_completion(config.BASE_URL, llm_model, messages, config.LLM_TEMPERATURE)
        print(answer)
        print()


def main() -> None:
    parser = argparse.ArgumentParser(description="Confluence RAG indexer")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_models = sub.add_parser("list-models", help="List available models")
    p_models.set_defaults(func=cmd_list_models)

    p_index = sub.add_parser("index", help="Build index from Confluence")
    p_index.add_argument("--model", help="Model ID to use for embeddings")
    p_index.set_defaults(func=cmd_index)

    p_index_pdf = sub.add_parser("index-pdf", help="Build index from a PDF file")
    p_index_pdf.add_argument("pdf", help="Path to a PDF file")
    p_index_pdf.add_argument("--model", help="Model ID to use for embeddings")
    p_index_pdf.set_defaults(func=cmd_index_pdf)

    p_search = sub.add_parser("search", help="Search the local index")
    p_search.add_argument("query")
    p_search.add_argument("--top-k", type=int, default=config.TOP_K)
    p_search.set_defaults(func=cmd_search)

    p_compare = sub.add_parser("compare", help="Compare answers with and without RAG")
    p_compare.add_argument("query")
    p_compare.add_argument("--top-k", type=int, default=config.TOP_K)
    p_compare.add_argument("--model", help="LLM model ID to use for generation")
    p_compare.add_argument("--max-chars", type=int, default=8000, help="Max context characters")
    p_compare.set_defaults(func=cmd_compare)

    p_chat = sub.add_parser("chat-rag", help="Interactive RAG chat")
    p_chat.add_argument("--top-k", type=int, default=config.TOP_K)
    p_chat.add_argument("--model", help="LLM model ID to use for generation")
    p_chat.add_argument("--max-chars", type=int, default=8000, help="Max context characters")
    p_chat.set_defaults(func=cmd_chat_rag)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
