# FAQ

## Plugin manager

### Why don't create the Plugin Manager inside the engine?
Since plugins are just dynamic libraries, this means that they can call any code, including system calls and other unsafe operations. Inside a child process, plugins still can create unsafe calls, but the risk is lower - it can't do much to the engine inside a small forked process.

### Why the plugin manager expects only load() and unload()?
Maybe there should be more functions, but I'll try to create Zorcerer as minimalistic as possible.

## ZLua

### Why ZLua?
Small, blazingly fast - the perfection for scripting language!

### Why not TypeScript/JavaScript?
Because JavaScript runtimes are heavy.

### Why not Lisp?
(question (Are '(statement-p (you serious))))

### Why not X?
I don't want to implement one billion runtimes that comes with Zorcerer. You are always free to do it by writing a plugin. 

By the way, you know that the plugin manager is kinda the plugin too? It just has more privileges. This means you can even implement a smaller Zorcerer if you want!

## Why AI slop
Yes, yes I know that AI is bad, etc. etc.

But let's be realistic. **They are much better at writing code than we, humans**. Still, they are extremely bad in creating algorithms and architecture. So I study, and already use math to give them a direction how to write the code. For example, see the commit **ce9cbe9f72f29f2620d3cdc905c00a598f8ad285**. That was the day I learned about mathematical logic. As I found out, it is nearly perfect for creating tests, and I will continue my experiments with agentic programming, using math in prompt creation.

As I write this document, yes, I extremely slop the project. Why? Because I need a working prototype. I need to see, whether my idea is viable? And if I see that it can work out, my vision on the Zorcerer can go much further. So one day, I promise that I will review before committing to the main branches. And I hope that day comes very soon.

Will I write the code manually? Hell no. Except for something small. Writing code manually became routine work. If you are against it, then I'll remind you: remember when the Assembly guys told that high-level languages are making us stupid, and the programs unsafe? And where we are now? The history repeats itself. I just don't miss the train of progress. But who is right? We will see when Zorcerer becomes something more than a prototype.

AI agents are not programmers. They are tools.

