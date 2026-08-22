SynexProtocol = {
    api = '1.0.0',
    wire = 1,
    events = {
        request = 'synex:rpc:v1:request',
        response = 'synex:rpc:v1:response',
        cancel = 'synex:rpc:v1:cancel',
        state = 'synex:state:v1:update'
    },
    limits = {
        requestId = 96,
        procedure = 128,
        traceId = 64,
        payloadBytes = 32768,
        tableDepth = 12,
        tableKeys = 512,
        stringBytes = 16384
    }
}
