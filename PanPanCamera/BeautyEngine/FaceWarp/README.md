# FaceWarp

The first product Face Correction path lives in `Rendering/CoreImage`, alongside the
existing Preview renderer. It consumes the current `DetectedFace` contour/eyebrow
landmarks and implements Preview-only Auto, Slim, Width, Chin, Forehead and Cheekbones.

Auto batch-sets all face parameters; implemented geometry controls multiply their
concrete strength by Auto.
The largest face wins, with distance to image center as a deterministic tie-breaker.
Local movements are feathered into one RG displacement map and one Core Image kernel
that explicitly decodes pixel sampling offsets. Missing/incomplete landmarks bypass
geometry. Eye, eye-spacing, eye-height,
nose and mouth controls, stable identity tracking, and final-photo face correction remain
future work. No image, landmark, or biometric data leaves the device.
