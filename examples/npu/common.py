"""Small model-building helpers shared by the examples."""
import numpy as np
import openvino as ov
import openvino.opset13 as op

rng = np.random.default_rng(0)


def weights(*shape, scale=0.05):
    return op.constant(rng.standard_normal(shape).astype(np.float32) * scale)


def conv(x, cin, cout, k=3, stride=1):
    """A k x k convolution, same padding."""
    p = k // 2
    return op.convolution(x, weights(cout, cin, k, k), [stride, stride], [p, p], [p, p], [1, 1])


def conv_flops(cin, cout, k, h, w):
    """Multiply-adds of a same-padded, stride-1 convolution, counted as 2 FLOPs each."""
    return 2 * cin * cout * k * k * h * w


def model(outputs, params, name):
    return ov.Model(outputs if isinstance(outputs, list) else [outputs], params, name)
