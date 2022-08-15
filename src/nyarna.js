class Nyarna {
  static instance;

  // --- public interface ---

  static async instantiate(wasmPath) {
    if (!this.instance) {
      this.instance = await WebAssembly.instantiate(fetch(wasmPath), {
        imports: {
          consoleLog: this.consoleLogZig,
        }
      });
    }
    return new Nyarna();
  }

  // --- private implementation ---

  constructor() {
    this.memory = Nyarna.instance.exports.memory;
  }

  static consoleLogZig(location, size) {
    console.log(new Nyarna().stringFromZig(location, size));
  }

  stringFromZig(ptr, size) {
    const buffer = new Uint8Array(this.memory.buffer, ptr, size);
    const decoder = new TextDecoder();
    return decoder.decode(buffer);
  }

  // returns an Uint8Array containing the UTF-8 encoded string.
  // if owned == true, Uint8Array must be free'd explicitly.
  stringToZig(val, owned) {
    const encoder = new TextEncoder();
    const buffer = encoder.encode(val);
    if (owned) {
      const ptr = this.instance.exports.allocStr(buffer.byteLength);
      const ret = new Uint8Array(this.memory.buffer, ptr, buffer.byteLength + 1);
      ret.set(buffer);
      return ret;
    } else return buffer;
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
    const zigName = this.nyarna.stringToZig(name, true);
    const zigContent = this.nyarna.stringToZig(content, true);
    Nyarna.instance.exports.pushInput(
      this.ptr, zigName.ptr, zigName.byteLength, zigContent.ptr, zigContent.byteLength);
  }

  pushArg(name, content) {
    const zigName = this.nyarna.stringToZig(name, true);
    const zigContent = this.nyarna.stringToZig(content, true);
    Nyarna.instance.exports.pushArg(
      this.ptr, zigName.ptr, zigName.byteLength, zigContent.ptr, zigContent.byteLength);
  }

  process(main) {
    const zigMain = this.nyarna.stringToZig(main, true);
    const resultPtr = Nyarna.instance.exports.process(
      this.ptr, zigMain.ptr, zigMain.byteLength);
    let result = null;
    if (resultPtr == null) {
      console.error("processing failed!");
    } else {
      result = new Result(resultPtr, this.nyarna);
    }
    this.destroy();
    return result;
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