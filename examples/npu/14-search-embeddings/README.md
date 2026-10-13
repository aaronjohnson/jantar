# 14 · Search embeddings: a small BERT, one sentence vs batches

**Where it shows up.** Semantic search in files and mail, "recall"-style
timelines, recommendations: each sentence or chunk becomes a vector, and
search compares vectors. Indexing means embedding millions of chunks, in
the background.

**Question.** Does batching sentences use the NPU better than one at a
time, and how many sentences a second can it embed?

**Prediction.** One sentence gives small matrices and low TOPS; batches of
8 and 32 raise sentences per second several-fold before levelling off.

**Measured** (MiniLM-L6 shapes: 6 layers, 384 features, 12 heads, 128
tokens a sentence; random weights; 3 trials, turbo, spreads ≤ 5%):

| batch | wall ms | sentences/s | TOPS |
| ---: | ---: | ---: | ---: |
| 1 | 1.17 | 860 | 2.5 |
| 8 | 4.40 | 1,820 | 5.2 |
| 32 | 17.5 | 1,830 | 5.2 |

**What it shows.**
- Batching doubles throughput (2.1×), then levels off already by a batch
  of 8: less than predicted. The matrix work fills the DPU at 8, and the
  rest (SHAVE's softmax and norms, DMA growing to 13–17%) scales with the
  batch.
- About 1,800 sentences a second: a mailbox of a million sentences in
  under ten minutes, in the background.
- For indexing, batch in 8s; for a single query, one at a time is fast
  enough (1.2 ms).
