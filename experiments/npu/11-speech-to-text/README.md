# 11 · Speech to text: Whisper's encoder on 30 s of audio

**Where it shows up.** Live captions, meeting transcripts and voice typing.
Whisper and its relatives listen in 30-second windows: an encoder turns the
audio into 1,500 tokens, then a decoder writes the words a token at a time
(the decoder behaves like 12-language-model's writing phase).

**Question.** How long does the encoder take for 30 s of audio, and where
does the time go?

**Prediction.** Tens of milliseconds even for the base model, hundreds of
times faster than real time; attention (SHAVE) takes a large share.

**Measured** (Whisper tiny: 4 layers, 384 features; base: 6 layers, 512;
real shapes, random weights; 3 trials, turbo, spreads ≤ 1%):

| model | wall ms | faster than real time | TOPS | DPU / SHAVE |
| --- | ---: | ---: | ---: | --- |
| tiny | 7.0 | 4,300× | 5.3 | 58% / 42% |
| base | 14.0 | 2,100× | 6.3 | 61% / 39% |

**What it shows.**
- Faster than predicted: 7 and 14 ms, not tens. Encoding is a small part
  of transcription; the token-by-token decoder takes longer.
- At 1,500 tokens SHAVE does about 40% of the work, nearly all of it
  attention: the compiler fuses each layer's attention into one SHAVE
  layer (7.7 of SHAVE's 8.5 ms in tiny), plus the layer norms. GELU fused
  into the matmuls on the DPU, as it did after convolutions in 02.
- Base does 2.4× the FLOPs of tiny in 2× the time: bigger matrices use
  the DPU a little better.
