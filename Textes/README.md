# Confluence RAG Indexer

## Setup

1. Edit `config.py` and set:
   - `CONFLUENCE_USER`
   - `CONFLUENCE_PASSWORD`
   - Optionally `BASE_URL`, `CONFLUENCE_URL`, and chunking/search params

2. Install deps:

```bash
python -m pip install -r requirements.txt
```

## Usage

List models from the local server:

```bash
python rag_agent.py list-models
```

Build the index (uses first model if `--model` omitted):

```bash
python rag_agent.py index
# or
python rag_agent.py index --model <model-id>
```

Build the index from a PDF:

```bash
python rag_agent.py index-pdf /path/to/file.pdf
# or
python rag_agent.py index-pdf /path/to/file.pdf --model <model-id>
```

Search the index:

```bash
python rag_agent.py search "Как подключить API?"
```

Compare answers with and without RAG:

```bash
python rag_agent.py compare "Как подключить API?"
# or
python rag_agent.py compare "Как подключить API?" --model <llm-model-id>
```

Interactive RAG chat:

```bash
python rag_agent.py chat-rag
# or
python rag_agent.py chat-rag --model <llm-model-id> --top-k 5 --max-chars 8000
```

The index is stored in `index.json`.
