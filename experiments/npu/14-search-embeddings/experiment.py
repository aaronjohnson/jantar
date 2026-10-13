"""Embeddings for search: a small BERT encoding sentences, alone or in batches."""
import numpy as np
import openvino.opset13 as op
from blocks import Net
from common import model

TITLE = "Search embeddings: a small BERT, one sentence vs batches"
REAL_WORLD = "semantic search in files and mail, recall, recommendations"
QUESTION = """Semantic search turns each sentence into a vector with a small
encoder (MiniLM, BERT-like: 6 layers, 384 features), then compares
vectors. Indexing a mailbox means millions of sentences. Does batching
sentences together use the NPU better than one at a time, and how many
sentences a second can it embed?"""
PREDICTION = """One sentence (128 tokens) gives small matrices and low TOPS;
batches of 8 and 32 make the matrix multiplies bigger, so sentences per
second rise several-fold before levelling off."""

D, HEADS, MLP, LAYERS, TOKENS = 384, 12, 1536, 6, 128


def encoder(batch):
    n = Net()
    # Token embeddings in (the lookup from words is a table read, left out).
    x = op.parameter([batch, TOKENS, D], np.float32)
    y = x
    for _ in range(LAYERS):
        y = n.encoder_layer(y, batch, TOKENS, D, HEADS, MLP)
    pooled = op.reduce_mean(y, op.constant([1]), False)  # one vector a sentence
    return model(pooled, [x], f"minilm{batch}"), n.flops


def variants():
    out = []
    for b in (1, 8, 32):
        m, f = encoder(b)
        out.append((f"MiniLM, batch of {b}", m, f))
    return out
