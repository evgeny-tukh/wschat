<?php

$port = 8000;

$server = stream_socket_server("tcp://0.0.0.0:$port", $errno, $errstr);

if (!$server) {
    die("$errstr ($errno)\n");
}

$connections = [];

while (true) {
    $readChannels = $connections + [$server];
    $writeChannels = $except = null;

    if (!stream_select ($readChannels, $writeChannels, $except, null)) {
        break;
    }

    if (in_array ($server, $readChannels)) {
        if (($connection = stream_socket_accept ($server, -1)) && $info = handshake ($connection)) {
            $connections []= $connection;
            
            onOpen ($connection, $info);
        }

        unset ($readChannels [array_search ($server, $readChannels)]);
    }

    foreach ($readChannels as $connection) {
        $data = fread ($connection, 100000);

        if ($data) {
            onMessage ($connection, $data);
        } else {
            fclose ($connection);
            unset ($connections [array_search ($connection, $connections)]);
            onClose ($connection);
        }
    }
}

fclose ($server);

function handshake ($connection) {
    $info = [];

    $line = fgets ($connection);
    $header = explode (' ', $line);
    $info ['method'] = $header [0];
    $info ['uri'] = $header [1];

    while ($line = rtrim (fgets ($connection))) {
        if (preg_match ('/\A(\S+): (.*)\z/', $line, $matches)) {
            $info [$matches [1]] = $matches [2];
        } else {
            break;
        }
    }

    $clientAddr = explode (':', stream_socket_get_name ($connection, true));
    $info ['ip'] = $clientAddr [0];
    $info ['port'] = $clientAddr [1];

    if (empty($info['Sec-WebSocket-Key'])) {
        return false;
    }

    $secWebsocketKey = $info['Sec-WebSocket-Key'].'258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
    $secWebSocketAcceptance = base64_encode (pack ('H*', sha1 ($secWebsocketKey)));
    $upgrade = "HTTP/1.1 101 Web Socket Protocol Handshake\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept:$secWebSocketAcceptance\r\n\r\n";

    fwrite ($connection, $upgrade);

    return $info;
}

function encode ($payload, $type = 'text', $masked = false) {
    $frameHead = [];
    $payloadLength = strlen($payload);

    switch ($type) {
        case 'text':
            // first byte indicates FIN, Text-Frame (10000001):
            $frameHead[0] = 129;
            break;

        case 'close':
            // first byte indicates FIN, Close Frame(10001000):
            $frameHead[0] = 136;
            break;

        case 'ping':
            // first byte indicates FIN, Ping frame (10001001):
            $frameHead[0] = 137;
            break;

        case 'pong':
            // first byte indicates FIN, Pong frame (10001010):
            $frameHead[0] = 138;
            break;
    }

    // set mask and payload length (using 1, 3 or 9 bytes)
    if ($payloadLength > 65535) {
        $payloadLengthBin = str_split(sprintf('%064b', $payloadLength), 8);
        $frameHead[1] = ($masked === true) ? 255 : 127;
        for ($i = 0; $i < 8; $i++) {
            $frameHead[$i + 2] = bindec($payloadLengthBin[$i]);
        }
        // most significant bit MUST be 0
        if ($frameHead[2] > 127) {
            return array('type' => '', 'payload' => '', 'error' => 'frame too large (1004)');
        }
    } elseif ($payloadLength > 125) {
        $payloadLengthBin = str_split(sprintf('%016b', $payloadLength), 8);
        $frameHead[1] = ($masked === true) ? 254 : 126;
        $frameHead[2] = bindec($payloadLengthBin[0]);
        $frameHead[3] = bindec($payloadLengthBin[1]);
    } else {
        $frameHead[1] = ($masked === true) ? $payloadLength + 128 : $payloadLength;
    }

    // convert frame-head to string:
    foreach (array_keys($frameHead) as $i) {
        $frameHead[$i] = chr($frameHead[$i]);
    }
    if ($masked === true) {
        // generate a random mask:
        $mask = array();
        for ($i = 0; $i < 4; $i++) {
            $mask[$i] = chr(rand(0, 255));
        }

        $frameHead = array_merge($frameHead, $mask);
    }
    $frame = implode('', $frameHead);

    // append payload to frame:
    for ($i = 0; $i < $payloadLength; $i++) {
        $frame .= ($masked === true) ? $payload[$i] ^ $mask[$i % 4] : $payload[$i];
    }

    return $frame;
}

function decode($data) {
    $unmaskedPayload = '';
    $decodedData = array();

    // estimate frame type:
    $firstByteBinary = sprintf('%08b', ord($data[0]));
    $secondByteBinary = sprintf('%08b', ord($data[1]));
    $opcode = bindec(substr($firstByteBinary, 4, 4));
    $isMasked = ($secondByteBinary[0] == '1') ? true : false;
    $payloadLength = ord($data[1]) & 127;

    // unmasked frame is received:
    if (!$isMasked) {
        return array('type' => '', 'payload' => '', 'error' => 'protocol error (1002)');
    }

    switch ($opcode) {
        // text frame:
        case 1:
            $decodedData['type'] = 'text';
            break;

        case 2:
            $decodedData['type'] = 'binary';
            break;

        // connection close frame:
        case 8:
            $decodedData['type'] = 'close';
            break;

        // ping frame:
        case 9:
            $decodedData['type'] = 'ping';
            break;

        // pong frame:
        case 10:
            $decodedData['type'] = 'pong';
            break;

        default:
            return array('type' => '', 'payload' => '', 'error' => 'unknown opcode (1003)');
    }

    if ($payloadLength === 126) {
        $mask = substr($data, 4, 4);
        $payloadOffset = 8;
        $dataLength = bindec(sprintf('%08b', ord($data[2])) . sprintf('%08b', ord($data[3]))) + $payloadOffset;
    } elseif ($payloadLength === 127) {
        $mask = substr($data, 10, 4);
        $payloadOffset = 14;
        $tmp = '';
        for ($i = 0; $i < 8; $i++) {
            $tmp .= sprintf('%08b', ord($data[$i + 2]));
        }
        $dataLength = bindec($tmp) + $payloadOffset;
        unset($tmp);
    } else {
        $mask = substr($data, 2, 4);
        $payloadOffset = 6;
        $dataLength = $payloadLength + $payloadOffset;
    }

    /**
     * We have to check for large frames here. socket_recv cuts at 1024 bytes
     * so if websocket-frame is > 1024 bytes we have to wait until whole
     * data is transferd.
     */
    if (strlen($data) < $dataLength) {
        return false;
    }

    if ($isMasked) {
        for ($i = $payloadOffset; $i < $dataLength; $i++) {
            $j = $i - $payloadOffset;
            if (isset($data[$i])) {
                $unmaskedPayload .= $data[$i] ^ $mask[$j % 4];
            }
        }
        $decodedData['payload'] = $unmaskedPayload;
    } else {
        $payloadOffset = $payloadOffset - 4;
        $decodedData['payload'] = substr($data, $payloadOffset);
    }

    return $decodedData;
}

function onOpen($connection, $info) {
    echo "opened\n";
    fwrite ($connection, encode('Hi there'));
}

function onClose ($connection) {
    echo "closed\n";
}

function onMessage($connection, $data) {
    echo decode($data)['payload']."\n";
}
