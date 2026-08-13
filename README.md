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

# the sad
once this is developed enough, i'm going to merge this with another private project I'm working on, so you won't get any more updates, sorry.
but not yet don't worry

*everything here is subject to change because I'm working on it as you read.
