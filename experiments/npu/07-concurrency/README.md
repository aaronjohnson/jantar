# 07 · Concurrency: requests in flight, and apps sharing the NPU

**Where it shows up.** A video call runs background blur, noise suppression
and live captions at once, possibly while an assistant answers a question;
indexing for search runs in the background all the while. Apps also keep
several inferences in flight, so the host prepares the next input while the
NPU works on the current one.

**Question.** How much does keeping requests in flight gain, what happens to
one app's latency when another loads the NPU, and does priority protect it?

**Prediction.** The host-bound blur model gains most from requests in flight
(up to ~3×), the NPU-bound convolution little. The blur's latency rises with
a language model prefilling in another process, and HIGH priority claws much
of that back.

**Measured** (blur = 10's MobileNetV2 segmenter at 256×256; conv = 01's
4× 256-channel convolutions; the other app = 12's Llama layer prefilling 512
tokens, back to back, in a separate process; OpenVINO's async queue; 5
trials, turbo, spreads ≤ 2%):

| variant | latency ms | per second | other app per second |
| --- | ---: | ---: | ---: |
| blur, 1 in flight | 0.53 | 2,990 | |
| blur, 2 in flight | 0.45 | 5,410 | |
| blur, 4 in flight | 0.80 | 5,550 | |
| conv, 1 in flight | 2.33 | 740 | |
| conv, 4 in flight | 4.58 | 1,020 | |
| blur, while another app prefills | **8.37** | 225 | 117 |
| blur at HIGH priority, the other at LOW | 0.76 | 2,170 | **29** |

**What it shows.**
- **In flight:** two requests nearly double the blur's throughput (1.8×):
  the host's half of each inference now overlaps the NPU's. Four add
  almost nothing more and each request waits longer: the NPU itself is
  then the limit. The NPU-bound convolution gains 1.4× from four. The
  prediction had the shape right, the size (~3×) too high.
- **Sharing:** with a language model prefilling in another app, each blur
  frame took **16× longer** (0.53 → 8.4 ms), about the length of one of
  the other app's prefill jobs (8.7 ms in 12). So at normal priority the
  NPU finishes the job it's on, or most of it, before taking the next:
  a short job waits behind a long one.
- **Priority works, and isn't free:** at HIGH priority (the other app at
  LOW) the blur is back to 0.76 ms, while the other app slows from 117 to
  29 prefills a second, 4×. The firmware's scheduler does preempt for
  priority, at the other app's expense.
- For a video call: give the effects HIGH priority, or a long background
  job can freeze them for frames at a time.

**Open.** Does the blur's wait track the other job's length? Try the other
app with short jobs (12's decode, 1.6 ms) and long ones.
