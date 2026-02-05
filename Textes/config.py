BASE_URL = "http://10.172.17.26:1234/v1"
CONFLUENCE_URL = "https://confluence.hexteam.tech/spaces/LIME/pages/80904221/Lime+Android+Home"
CONFLUENCE_USER = "YOUR_USERNAME"
CONFLUENCE_PASSWORD = "YOUR_PASSWORD"

INDEX_PATH = "index.json"

# LLM generation
LLM_MODEL = "qwen/qwen3-coder-30b"
LLM_TEMPERATURE = 0.2
LLM_TIMEOUT_SEC = 600
EMBED_TIMEOUT_SEC = 300

# Chunking (by words)
CHUNK_SIZE_WORDS = 200
CHUNK_OVERLAP_WORDS = 40

# Indexing limits
MAX_PAGES = 200
BATCH_SIZE = 64

# Search
TOP_K = 5
