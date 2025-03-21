class PCMProcessor extends AudioWorkletProcessor {
    constructor() {
        super();
        this.buffer = new Float32Array();

        // Correct way to handle messages in AudioWorklet
        this.port.onmessage = (e) => {
            const newData = e.data;
            
            // Handle different data types that might come from Dart
            let float32Data;
            if (newData instanceof Float32Array) {
                float32Data = newData;
            } else if (Array.isArray(newData)) {
                float32Data = new Float32Array(newData);
            } else {
                console.error('Invalid PCM data format received in AudioWorklet');
                return;
            }
            
            const newBuffer = new Float32Array(this.buffer.length + float32Data.length);
            newBuffer.set(this.buffer);
            newBuffer.set(float32Data, this.buffer.length);
            this.buffer = newBuffer;
            
            console.log(`Received ${float32Data.length} PCM samples, buffer now ${this.buffer.length} samples`);
        };
    }

    process(inputs, outputs) {
        const output = outputs[0][0];
        const length = Math.min(this.buffer.length, output.length);
        
        if (length > 0) {
            output.set(this.buffer.subarray(0, length));
            this.buffer = this.buffer.subarray(length);
        }
        
        return true;
    }
}

registerProcessor('pcm-processor', PCMProcessor); 