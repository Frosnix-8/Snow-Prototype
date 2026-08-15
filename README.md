# Snow Prototype
Welcome, this is my repo for my snow prototype! 

## What is it?
Snow.
To be more precise, a snow system designed for a certain size, about 96x96 meters, designed to be both detailed enough
for an fps game revolving around snow mechanics both visually and physically. It is extremely efficient and runs smoothly using only a couple threads for performance.

### How does it work?
There are two versions. one sucks and one doesn't. The first uses dual viewports in a ping-pong system. This was my first
iteration. it gives you deterministic snow deformation (useful for online games) but it's heavy since you have lots of subviewports and stamps!

The second iteration is substantially better. I gave compute shaders a go, and it allows me to use max blending for snow, as well as removing the
need for subviewports and stamp nodes. instead these are all in-code, which simplifies and improves performance by miles.

on the CPU side, this system uses dedicated to calculate CPU-side arrays for collisions and more. up to 256 64x64 grids is heavy!
in practice, a single tile only needs less than  1-2 ms of work to completely do all the CPU black magic I coded. It's just some deformation and
downsampling for quality.

## Can I use it?
yes of course! I don't care what you do with it (please give me credit please please please). But.
# But
bear in mind this project was not made for you, it is made for my personal work. So feel free to adjust things to your liking!

# features
-a simple snow shader I made for this specific snow system.
-6x6 snow tiles you can arrange however you want, as long as they're positioned on multiples of 6.
-great performance right now
-the ability to make the tiles shear vertically!!! this does not cause issues, works perfectly fine! don't rotate, shear!!! (there is a debug for editors)
-whatever else i'm gonna add later.
-a few presets for when you have something move through snow, including but not limited to player movement, footsteps, explosions, and especially things that increase snow level
-the ability to increase the snow level everywhere at once.

# Performance Requirements
This system requires you have at least 6 cores preferably, something with hyper threading so you have at least a dozen threads or so to work. this system is a bit expensive on the threads size but is adaptive. it can use up to 3 threads for the work it does, not including threads created and used internally by Godot.
Graphically, this is a very light project. work has been done to make ambient occlusion and GI less necessary on the snow alone. if you have things in snow then it's maybe useful. For now, no post-processing except glow is enabled. you can run this on integrated GPUs from the intel 10th gen lineup, and I suppose all later generations, including those from AMD. on an RTX 2060 mobile max-Q, (power limited to 60W), you can get about 500 fps consistently, or frame times of about 1.5 Ms. most GPUs today, if you have any gaming pc, will run even better graphics. Proof that it's pretty good!

*everything here is subject to change because I'm working on it as you read.

# Instructions for use
initialize as a submodule in your project. Don't forget to remove project.godot. Otherwise, it will not be recognized by godot.
