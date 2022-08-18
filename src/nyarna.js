class Nyarna {
  static instance;

  // --- public interface ---

  static async instantiate(wasmPath) {
    if (!this.instance) {
      const result = await WebAssembly.instantiateStreaming(fetch(wasmPath), {
        env: {
          consoleLog: this.consoleLogZig,
          memcpy: this.memcpyZig,
          memset: this.memsetZig,
          fmod: this.fmodZig,
          throwPanic: this.throwPanicZig,
        }
      });
      this.instance = result.instance;
    }
    return new Nyarna();
  }

  // --- private implementation ---

  constructor() {
    this.memory = Nyarna.instance.exports.memory;
  }

  static consoleLogZig(desc, descSize, msg, msgSize) {
    const ny = new Nyarna();
    console.log("[nyarna-wasm]", ny.stringFromZig(desc, descSize),
      ny.stringFromZig(msg, msgSize));
  }

  static memcpyZig(dest, src, count) {
    const ny = new Nyarna();
    const srcBuf = new Uint8Array(ny.memory.buffer, src, count);
    const destBuf = new Uint8Array(ny.memory.buffer, dest, count);
    destBuf.set(srcBuf);
    return dest;
  }

  static memsetZig(dest, ch, count) {
    const buffer = new Uint8Array(new Nyarna().memory.buffer, dest, count);
    buffer.fill(ch);
    return dest;
  }

  static fmodZig(x, y) {
    return Number((x - (Math.floor(x / y) * y)).toPrecision(8));
  }

  static throwPanicZig(msg, msgSize) {
    throw new Error(new Nyarna().stringFromZig(msg, msgSize));
  }

  stringFromZig(ptr, size) {
    const buffer = new Uint8Array(this.memory.buffer, ptr, size);
    const decoder = new TextDecoder();
    return decoder.decode(buffer);
  }
}

class Input {
  constructor(nyarna) {
    this.nyarna = nyarna;
    this.ptr = Nyarna.instance.exports.createInput();
  }

  destroy() {
    if (this.ptr != null) {
      Nyarna.instance.exports.destroyInput(this.ptr);
      this.ptr = null;
    }
  }

  pushInput(name, content) {
    const zigName = this.stringToZig(name, true);
    const zigContent = this.stringToZig(content, true, true);
    Nyarna.instance.exports.pushInput(
      this.ptr, zigName.byteOffset, zigName.byteLength,
      zigContent.byteOffset, zigContent.byteLength);
  }

  pushArg(name, content) {
    const zigName = this.stringToZig(name, true);
    const zigContent = this.stringToZig(content, true);
    Nyarna.instance.exports.pushArg(
      this.ptr, zigName.byteOffset, zigName.byteLength, zigContent.byteOffset, zigContent.byteLength);
  }

  process(main) {
    const zigMain = this.stringToZig(main, true);
    const resultPtr = Nyarna.instance.exports.process(
      this.ptr, zigMain.byteOffset, zigMain.byteLength);
    let result = null;
    if (resultPtr == null) {
      console.error("processing failed!");
    } else {
      result = new Result(resultPtr, this.nyarna);
    }
    this.destroy();
    return result;
  }

  // --- internal stuff ---

  // returns an Uint8Array containing the UTF-8 encoded string.
  // if owned == true, Uint8Array must be free'd explicitly.
  stringToZig(val, owned, addPadding) {
    const encoder = new TextEncoder();
    const buffer = encoder.encode(val);
    if (owned) {
      const ptr = Nyarna.instance.exports.allocStr(this.ptr, buffer.byteLength);
      const ret = new Uint8Array(this.nyarna.memory.buffer, ptr, buffer.byteLength + (addPadding ? 4 : 0));
      ret.set(buffer);
      if (addPadding) {
        ret.set([4, 4, 4, 4], buffer.byteLength);
      }
      return ret;
    } else return buffer;
  }
}

class Result {
  constructor(ptr, nyarna) {
    if (Nyarna.instance.exports.errorLength(ptr) > 0) {
      this.errors = nyarna.stringFromZig(
        Nyarna.instance.exports.errorOutput(ptr),
        Nyarna.instance.exports.errorLength(ptr),
      );
    } else {
      this.documents = [];
      for (let i = 0; i < Nyarna.instance.exports.outputLength(ptr); i++) {
        this.documents.push({
          name: this.nyarna.stringFromZig(
            Nyarna.instance.exports.documentName(ptr, i),
            Nyarna.instance.exports.documentNameLength(ptr, i)
          ),
          content: this.nyarna.stringFromZig(
            Nyarna.instance.exports.documentContent(ptr, i),
            Nyarna.instance.exports.documentContentLength(ptr, i)
          ),
        });
      }
    }
  }
}

export {Nyarna, Input, Result};