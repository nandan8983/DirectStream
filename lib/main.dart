import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:network_info_plus/network_info_plus.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

const String kGithubRepo = 'nandan8983/DirectStream';
const int kReceiverPort = 8080;
const int kDiscoveryUdpPort = 45454;
const String kMqttBroker = 'broker.emqx.io';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const DirectStreamApp());
}

@pragma("vm:entry-point")
void overlayMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: BackgroundOverlayPrompt(),
  ));
}

// ============================================================================
// DATA MODELS (Stream Quality, Discovered TV, Playback History)
// ============================================================================
class StreamQualityOption {
  final String label; // e.g., "1080p", "720p", "360p", "Auto (HLS)"
  final String url;

  StreamQualityOption({required this.label, required this.url});

  Map<String, dynamic> toJson() => {'label': label, 'url': url};
  factory StreamQualityOption.fromJson(Map<String, dynamic> json) =>
      StreamQualityOption(label: json['label'] ?? 'Auto', url: json['url'] ?? '');
}

class DiscoveredReceiver {
  final String name;
  final String ip;
  final int port;
  final String roomCode;
  final String mode; // 'LAN' or 'Router-Bypass'

  DiscoveredReceiver({
    required this.name,
    required this.ip,
    required this.port,
    required this.roomCode,
    this.mode = 'LAN',
  });

  String get wsUrl => 'ws://$ip:$port';
}

class PlaybackHistoryItem {
  final String title;
  final String originalUrl;
  final String streamUrl;
  final List<StreamQualityOption> qualities;
  final String timestamp;

  PlaybackHistoryItem({
    required this.title,
    required this.originalUrl,
    required this.streamUrl,
    required this.qualities,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'title': title,
        'originalUrl': originalUrl,
        'streamUrl': streamUrl,
        'qualities': qualities.map((q) => q.toJson()).toList(),
        'timestamp': timestamp,
      };

  factory PlaybackHistoryItem.fromJson(Map<String, dynamic> json) {
    final rawQualities = (json['qualities'] as List?) ?? [];
    return PlaybackHistoryItem(
      title: json['title'] ?? 'Video Stream',
      originalUrl: json['originalUrl'] ?? '',
      streamUrl: json['streamUrl'] ?? '',
      qualities: rawQualities
          .map((q) => StreamQualityOption.fromJson(Map<String, dynamic>.from(q)))
          .toList(),
      timestamp: json['timestamp'] ?? '',
    );
  }
}

// ============================================================================
// GITHUB AUTO-UPDATER SERVICE
// ============================================================================
class GitHubAutoUpdater {
  /// Parses a semver-style string like "0.0.4" into comparable integers.
  static List<int> _parseVersion(String v) {
    return v
        .replaceAll(RegExp(r'[^0-9.]'), '')
        .split('.')
        .map((p) => int.tryParse(p) ?? 0)
        .toList();
  }

  /// Returns true when [remoteVer]/[remoteBuild] is strictly newer than local.
  static bool _isNewer(
      String remoteVer, int remoteBuild, String localVer, int localBuild) {
    final rem = _parseVersion(remoteVer);
    final loc = _parseVersion(localVer);
    final len = max(rem.length, loc.length);
    for (int i = 0; i < len; i++) {
      final r = i < rem.length ? rem[i] : 0;
      final l = i < loc.length ? loc[i] : 0;
      if (r > l) return true;
      if (r < l) return false;
    }
    // Version strings equal — compare build numbers
    return remoteBuild > localBuild;
  }

  static Future<void> checkForUpdate(BuildContext context,
      {bool silentIfUpToDate = true}) async {
    try {
      final PackageInfo packageInfo = await PackageInfo.fromPlatform();
      final int currentBuild = int.tryParse(packageInfo.buildNumber) ?? 0;
      final String currentVersion = packageInfo.version; // e.g. "0.0.4"

      final response = await http.get(
        Uri.parse(
            'https://api.github.com/repos/$kGithubRepo/releases/latest'),
        headers: {'Accept': 'application/vnd.github.v3+json'},
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        if (!silentIfUpToDate && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'No GitHub release found yet (HTTP ${response.statusCode}). '
                'Push your code so Actions can build & publish a release.',
              ),
            ),
          );
        }
        return;
      }

      final Map<String, dynamic> release = jsonDecode(response.body);
      final String tagName =
          (release['tag_name'] ?? '').toString().trim();
      final String releaseNotes =
          (release['body'] ?? 'New version available.').toString().trim();

      // Parse remote version & build number from tag (e.g. "v0.0.5+5")
      final String tagStripped =
          tagName.startsWith('v') ? tagName.substring(1) : tagName;
      final List<String> tagParts =
          tagStripped.split(RegExp(r'[+\-]'));
      final String remoteVersion =
          tagParts.isNotEmpty ? tagParts[0] : tagStripped;
      final int remoteBuild =
          tagParts.length > 1 ? (int.tryParse(tagParts[1]) ?? 0) : 0;

      final bool hasUpdate =
          _isNewer(remoteVersion, remoteBuild, currentVersion, currentBuild);

      if (!hasUpdate) {
        if (!silentIfUpToDate && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'You are already on the latest version '
                '(v$currentVersion+$currentBuild).',
              ),
            ),
          );
        }
        return;
      }

      // Find the APK download URL among the release assets
      String? apkDownloadUrl;
      final List<dynamic> assets = release['assets'] ?? [];
      for (final asset in assets) {
        final String name =
            (asset['name'] ?? '').toString().toLowerCase();
        if (name.endsWith('.apk')) {
          apkDownloadUrl =
              (asset['browser_download_url'] ?? '').toString();
          break;
        }
      }

      if (apkDownloadUrl == null || apkDownloadUrl.isEmpty) {
        if (!silentIfUpToDate && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Update $tagName is available but the APK is not ready yet. '
                'Check GitHub Actions for build progress.',
              ),
            ),
          );
        }
        return;
      }

      if (context.mounted) {
        _showUpdateDialog(
          context,
          tagName: tagName,
          currentVersion: 'v$currentVersion+$currentBuild',
          notes: releaseNotes,
          apkUrl: apkDownloadUrl,
        );
      }
    } catch (e) {
      if (!silentIfUpToDate && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Update check failed: $e')),
        );
      }
    }
  }

  static void _showUpdateDialog(
    BuildContext context, {
    required String tagName,
    required String currentVersion,
    required String notes,
    required String apkUrl,
  }) {
    bool isDownloading = false;
    double progress = 0.0;
    String statusText = '';

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.system_update, color: Colors.tealAccent),
              const SizedBox(width: 10),
              Expanded(child: Text('Update Available ($tagName)')),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Installed: $currentVersion',
                style:
                    const TextStyle(color: Colors.grey, fontSize: 13),
              ),
              const SizedBox(height: 8),
              Text(notes, maxLines: 5, overflow: TextOverflow.ellipsis),
              if (isDownloading) ...[
                const SizedBox(height: 20),
                LinearProgressIndicator(
                  value: progress > 0 ? progress : null,
                  color: Colors.tealAccent,
                ),
                const SizedBox(height: 8),
                Text(
                  statusText,
                  style: const TextStyle(
                      fontSize: 13, color: Colors.tealAccent),
                ),
              ],
            ],
          ),
          actions: [
            if (!isDownloading)
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Later',
                    style: TextStyle(color: Colors.grey)),
              ),
            ElevatedButton.icon(
              autofocus: true,
              onPressed: isDownloading
                  ? null
                  : () async {
                      setDialogState(() {
                        isDownloading = true;
                        statusText = 'Connecting to GitHub...';
                        progress = 0.0;
                      });
                      try {
                        final httpClient = http.Client();
                        final req =
                            http.Request('GET', Uri.parse(apkUrl));
                        final streamedRes = await httpClient
                            .send(req)
                            .timeout(const Duration(seconds: 30));

                        if (streamedRes.statusCode != 200) {
                          throw Exception(
                              'Server returned HTTP ${streamedRes.statusCode}');
                        }

                        final totalBytes =
                            streamedRes.contentLength ?? 0;
                        int receivedBytes = 0;

                        final dir = await getTemporaryDirectory();
                        final apkFile =
                            File('${dir.path}/DirectStream-update.apk');
                        if (await apkFile.exists()) {
                          await apkFile.delete();
                        }
                        final sink = apkFile.openWrite();

                        setDialogState(
                            () => statusText = 'Downloading update...');

                        await for (final chunk in streamedRes.stream) {
                          receivedBytes += chunk.length;
                          sink.add(chunk);
                          if (totalBytes > 0) {
                            setDialogState(() {
                              progress = receivedBytes / totalBytes;
                              final mb = (receivedBytes / 1048576)
                                  .toStringAsFixed(1);
                              final tot = (totalBytes / 1048576)
                                  .toStringAsFixed(1);
                              statusText =
                                  'Downloading: ${(progress * 100).toStringAsFixed(0)}%  ($mb / $tot MB)';
                            });
                          }
                        }
                        await sink.flush();
                        await sink.close();
                        httpClient.close();

                        setDialogState(
                            () => statusText = 'Opening installer...');
                        if (ctx.mounted) Navigator.pop(ctx);
                        final result =
                            await OpenFilex.open(apkFile.path);
                        if (result.type != ResultType.done &&
                            ctx.mounted) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            SnackBar(
                              content: Text(
                                  'Could not open installer: ${result.message}'),
                              backgroundColor: Colors.redAccent,
                            ),
                          );
                        }
                      } catch (e) {
                        setDialogState(() {
                          isDownloading = false;
                          statusText = 'Download failed: $e';
                        });
                      }
                    },
              icon: const Icon(Icons.download),
              label:
                  Text(isDownloading ? 'Updating...' : 'Update Now'),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// APP ROOT & MODE SELECTION
// ============================================================================
class DirectStreamApp extends StatelessWidget {
  const DirectStreamApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: <LogicalKeySet, Intent>{
        LogicalKeySet(LogicalKeyboardKey.select): const ActivateIntent(),
        LogicalKeySet(LogicalKeyboardKey.enter): const ActivateIntent(),
      },
      child: MaterialApp(
        title: 'DirectStream',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark().copyWith(
          colorScheme: const ColorScheme.dark(
            primary: Colors.tealAccent,
            secondary: Colors.cyanAccent,
          ),
          scaffoldBackgroundColor: const Color(0xFF0F171E),
        ),
        home: const ModeSelectionScreen(),
      ),
    );
  }
}

class ModeSelectionScreen extends StatefulWidget {
  const ModeSelectionScreen({super.key});

  @override
  State<ModeSelectionScreen> createState() => _ModeSelectionScreenState();
}

class _ModeSelectionScreenState extends State<ModeSelectionScreen> {
  String _versionLabel = 'v0.0.8';

  @override
  void initState() {
    super.initState();
    _loadPackageVersion();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      GitHubAutoUpdater.checkForUpdate(context, silentIfUpToDate: true);
    });
  }

  Future<void> _loadPackageVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() {
        _versionLabel = 'v${info.version}+${info.buildNumber}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          TextButton.icon(
            onPressed: () => GitHubAutoUpdater.checkForUpdate(context, silentIfUpToDate: false),
            icon: const Icon(Icons.system_update, size: 18, color: Colors.tealAccent),
            label: Text('Check Update ($_versionLabel)', style: const TextStyle(color: Colors.tealAccent)),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 500),
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(
                    color: const Color(0xFF16222D),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: Colors.tealAccent.withOpacity(0.5), width: 2),
                  ),
                  child: const Stack(
                    alignment: Alignment.center,
                    children: [
                      Icon(Icons.tv, size: 64, color: Colors.tealAccent),
                      Padding(
                        padding: EdgeInsets.only(bottom: 6),
                        child: Icon(Icons.play_arrow_rounded, size: 34, color: Colors.cyanAccent),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'DirectStream',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  'Wi-Fi Discovery • Router Bypass • YT/IG ($_versionLabel)',
                  style: const TextStyle(color: Colors.tealAccent, fontSize: 13),
                ),
                const SizedBox(height: 32),
                _RoleCard(
                  autofocus: true,
                  icon: Icons.tv,
                  title: 'TV Receiver Mode',
                  subtitle: 'Broadcasts on Wi-Fi + Cloud Relay, plays YouTube/IG/IPTV with Speed & Quality controls',
                  onTap: () => Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(builder: (_) => const TvReceiverScreen()),
                  ),
                ),
                const SizedBox(height: 16),
                _RoleCard(
                  autofocus: false,
                  icon: Icons.smartphone,
                  title: 'Phone Controller Mode',
                  subtitle: 'Auto-discovers TVs on Wi-Fi, saves Playback History, controls Speed & Quality',
                  onTap: () => Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(builder: (_) => const ControllerScreen()),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RoleCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool autofocus;

  const _RoleCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      autofocus: autofocus,
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      focusColor: Colors.tealAccent.withOpacity(0.25),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.white24),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(icon, size: 42, color: Colors.tealAccent),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(subtitle, style: const TextStyle(color: Colors.grey, fontSize: 13)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// TV RECEIVER MODE (HTTP/WS + UDP Discovery + MQTT Router-Isolation Bypass)
// ============================================================================
class TvReceiverScreen extends StatefulWidget {
  const TvReceiverScreen({super.key});

  @override
  State<TvReceiverScreen> createState() => _TvReceiverScreenState();
}

class _TvReceiverScreenState extends State<TvReceiverScreen> with WidgetsBindingObserver {
  HttpServer? _server;
  RawDatagramSocket? _udpSocket;
  MqttServerClient? _mqttClient;
  final List<WebSocket> _sockets = [];

  String _localIp = '127.0.0.1';
  String _pairingQrData = 'Initializing...';
  String _roomCode = '------';
  String _deviceName = 'DirectStream TV';
  bool _mqttConnected = false;
  bool _isForeground = true;

  VideoPlayerController? _videoController;
  ChewieController? _chewieController;
  String? _currentStreamUrl;
  String _currentTitle = 'Stream';
  double _currentSpeed = 1.0;
  String _currentQualityLabel = 'Auto';
  List<StreamQualityOption> _availableQualities = [];
  bool _showOverlayControls = true;
  Timer? _controlsTimer;

  void _scheduleControlsAutoHide() {
    _controlsTimer?.cancel();
    _controlsTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _showOverlayControls) {
        setState(() {
          _showOverlayControls = false;
        });
      }
    });
  }

  void _revealControls() {
    if (!_showOverlayControls) {
      setState(() {
        _showOverlayControls = true;
      });
    }
    _scheduleControlsAutoHide();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initReceiverServices();
    _listenToOverlayEvents();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isForeground = (state == AppLifecycleState.resumed);
  }

  void _updatePairingState() {
    _deviceName = 'DirectStream TV (${_localIp.split('.').last})';
    _pairingQrData = jsonEncode({
      'ws': 'ws://$_localIp:$kReceiverPort',
      'room': _roomCode,
      'name': _deviceName,
      'ip': _localIp,
    });
    if (mounted) {
      setState(() {});
    }
  }

  /// Detects real local IP address (prioritizing NetworkInterface which doesn't need location perms)
  Future<String?> _detectLocalIp() async {
    // 1. NetworkInterface.list is primary (works on Android TV Wi-Fi & Ethernet cable)
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );

      // Prioritize private LAN addresses: 192.168.x.x, 10.x.x.x, 172.16-31.x.x
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback && addr.type == InternetAddressType.IPv4) {
            final ip = addr.address;
            if (ip.startsWith('192.168.') || ip.startsWith('10.') || ip.startsWith('172.')) {
              return ip;
            }
          }
        }
      }

      // Fallback: any non-loopback IPv4
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback && addr.type == InternetAddressType.IPv4 && addr.address != '127.0.0.1') {
            return addr.address;
          }
        }
      }
    } catch (_) {}

    // 2. Fallback to network_info_plus with try-catch
    try {
      final info = NetworkInfo();
      final wifiIp = await info.getWifiIP().timeout(const Duration(seconds: 2));
      if (wifiIp != null && wifiIp.isNotEmpty && wifiIp != '127.0.0.1') {
        return wifiIp;
      }
    } catch (_) {}

    return null;
  }

  Future<void> _initReceiverServices() async {
    // 1. Instantly read/generate 6-digit room code and show it on TV UI immediately!
    try {
      final prefs = await SharedPreferences.getInstance();
      String? savedCode = prefs.getString('tv_room_code');
      if (savedCode == null || savedCode.length != 6) {
        savedCode = (100000 + Random().nextInt(899999)).toString();
        await prefs.setString('tv_room_code', savedCode);
      }
      _roomCode = savedCode;
    } catch (_) {
      _roomCode = (100000 + Random().nextInt(899999)).toString();
    }
    _updatePairingState(); // Instantly updates pairing code on TV screen!

    // 2. Safe, non-blocking overlay check with timeout (will not hang or crash on Android TV)
    try {
      final bool hasOverlayPerm = await FlutterOverlayWindow.isPermissionGranted()
          .timeout(const Duration(milliseconds: 600), onTimeout: () => false);
      if (!hasOverlayPerm) {
        await FlutterOverlayWindow.requestPermission()
            .timeout(const Duration(milliseconds: 800), onTimeout: () => false);
      }
    } catch (_) {}

    // 3. Detect Real IP (Ethernet cable or Wi-Fi)
    final detectedIp = await _detectLocalIp();
    if (detectedIp != null && detectedIp.isNotEmpty) {
      _localIp = detectedIp;
    }
    _updatePairingState(); // Instantly updates IP address and QR code!

    // 4. Start Local LAN Servers
    await _startHttpAndWebSocketServer();
    await _startUdpDiscoveryResponder();

    // 5. Connect to MQTT Relay in background (non-blocking)
    _connectMqttRelay();
  }

  Future<void> _startHttpAndWebSocketServer() async {
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, kReceiverPort, shared: true);
      _server!.listen((HttpRequest req) {
        // 1. Discovery endpoint for Wi-Fi Subnet Scanner
        if (req.uri.path == '/discover') {
          req.response.headers.contentType = ContentType.json;
          req.response.headers.add('Access-Control-Allow-Origin', '*');
          req.response.write(jsonEncode({
            'app': 'DirectStream',
            'name': _deviceName,
            'ip': _localIp,
            'port': kReceiverPort,
            'room': _roomCode,
          }));
          req.response.close();
          return;
        }
        // 2. WebSocket Upgrade for Direct LAN Control
        if (WebSocketTransformer.isUpgradeRequest(req)) {
          WebSocketTransformer.upgrade(req).then((WebSocket ws) {
            _sockets.add(ws);
            if (mounted) setState(() {});
            ws.listen(
              (data) => _handleControllerPayload(jsonDecode(data)),
              onDone: () {
                _sockets.remove(ws);
                if (mounted) setState(() {});
              },
            );
          });
        } else {
          req.response.statusCode = HttpStatus.ok;
          req.response.write('DirectStream TV Receiver Active ($_deviceName)');
          req.response.close();
        }
      });
    } catch (_) {}
  }

  Future<void> _startUdpDiscoveryResponder() async {
    try {
      _udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, kDiscoveryUdpPort);
      _udpSocket!.broadcastEnabled = true;
      _udpSocket!.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          final dg = _udpSocket!.receive();
          if (dg == null) return;
          final msg = utf8.decode(dg.data).trim();
          if (msg == 'DIRECTSTREAM_DISCOVER') {
            final reply = utf8.encode(jsonEncode({
              'app': 'DirectStream',
              'name': _deviceName,
              'ip': _localIp,
              'port': kReceiverPort,
              'room': _roomCode,
            }));
            _udpSocket!.send(reply, dg.address, dg.port);
          }
        }
      });
    } catch (_) {}
  }

  /// Connects to MQTT Broker so even if the Wi-Fi router has AP Isolation enabled,
  /// the phone can still discover and control the TV instantaneously!
  Future<void> _connectMqttRelay() async {
    final clientId = 'ds_tv_${_roomCode}_${Random().nextInt(9999)}';
    final client = MqttServerClient(kMqttBroker, clientId);
    client.port = 1883;
    client.keepAlivePeriod = 30;
    client.autoReconnect = true;
    client.logging(on: false);

    client.onConnected = () {
      if (mounted) setState(() => _mqttConnected = true);
      final cmdTopic = 'directstream/room/$_roomCode/cmd';
      client.subscribe(cmdTopic, MqttQos.atLeastOnce);

      // Also subscribe to global discovery topic for same-router devices
      client.subscribe('directstream/lan/discover', MqttQos.atMostOnce);
    };
    client.onDisconnected = () {
      if (mounted) setState(() => _mqttConnected = false);
    };

    try {
      await client.connect().timeout(const Duration(seconds: 5));
      _mqttClient = client;
      client.updates?.listen((List<MqttReceivedMessage<MqttMessage?>>? c) {
        if (c == null || c.isEmpty) return;
        final recMess = c[0].payload as MqttPublishMessage;
        final topic = c[0].topic;
        final payloadStr = MqttPublishPayload.bytesToStringAsString(recMess.payload.message);

        if (topic == 'directstream/lan/discover') {
          // Reply with our TV details so the phone's Wi-Fi scanner sees us even across AP Isolation
          final builder = MqttClientPayloadBuilder();
          builder.addString(jsonEncode({
            'app': 'DirectStream',
            'name': _deviceName,
            'ip': _localIp,
            'port': kReceiverPort,
            'room': _roomCode,
          }));
          client.publishMessage('directstream/lan/announce', MqttQos.atMostOnce, builder.payload!);
        } else {
          _handleControllerPayload(jsonDecode(payloadStr));
        }
      });
    } catch (_) {}
  }

  void _listenToOverlayEvents() {
    try {
      FlutterOverlayWindow.overlayListener.listen((event) {
        if (event is Map && event['action'] == 'ACCEPT') {
          _startVideoPlayback(event['url'], title: event['title'] ?? 'Stream');
        }
      }, onError: (_) {});
    } catch (_) {}
  }

  Future<void> _handleControllerPayload(Map<String, dynamic> payload) async {
    final String cmd = payload['command'] ?? '';
    final String? url = payload['url'];

    if (cmd == 'PLAY' && url != null) {
      final String title = payload['title'] ?? 'Video Stream';
      final String qualityLabel = payload['qualityLabel'] ?? 'Auto';
      final List<dynamic> rawQualities = payload['qualities'] ?? [];
      _availableQualities = rawQualities
          .map((q) => StreamQualityOption.fromJson(Map<String, dynamic>.from(q)))
          .toList();
      _currentQualityLabel = qualityLabel;

      if (_isForeground) {
        _startVideoPlayback(url, title: title);
      } else {
        final bool canOverlay = await FlutterOverlayWindow.isPermissionGranted();
        if (canOverlay) {
          await FlutterOverlayWindow.showOverlay(
            enableDrag: false,
            height: 280,
            width: 550,
            alignment: OverlayAlignment.bottomRight,
          );
          await FlutterOverlayWindow.shareData({'url': url, 'title': title});
        } else {
          _showAcceptRejectDialog(url, title);
        }
      }
    } else if (cmd == 'PAUSE') {
      _videoController?.pause();
      if (mounted) setState(() {});
    } else if (cmd == 'RESUME') {
      _videoController?.play();
      if (mounted) setState(() {});
    } else if (cmd == 'STOP') {
      _disposePlayer();
      setState(() => _currentStreamUrl = null);
    } else if (cmd == 'SPEED') {
      final double speed = (payload['speed'] as num?)?.toDouble() ?? 1.0;
      _setPlaybackSpeed(speed);
    } else if (cmd == 'QUALITY' && url != null) {
      final String label = payload['qualityLabel'] ?? 'Auto';
      _switchStreamQuality(url, label);
    }
  }

  Future<void> _setPlaybackSpeed(double speed) async {
    _currentSpeed = speed;
    await _videoController?.setPlaybackSpeed(speed);
    if (mounted) setState(() {});
  }

  Future<void> _switchStreamQuality(String newUrl, String label) async {
    final Duration currentPos = _videoController?.value.position ?? Duration.zero;
    _currentQualityLabel = label;
    await _startVideoPlayback(newUrl, title: _currentTitle, startAt: currentPos);
  }

  void _showAcceptRejectDialog(String url, String title) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text('Incoming Stream: $title'),
        content: Text('Play incoming stream on TV?\n\n$url', maxLines: 3, overflow: TextOverflow.ellipsis),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Reject', style: TextStyle(color: Colors.redAccent)),
          ),
          ElevatedButton(
            autofocus: true,
            onPressed: () {
              Navigator.pop(ctx);
              _startVideoPlayback(url, title: title);
            },
            child: const Text('Accept & Play'),
          ),
        ],
      ),
    );
  }

  Future<void> _startVideoPlayback(String url, {String title = 'Stream', Duration? startAt}) async {
    _disposePlayer();
    setState(() {
      _currentStreamUrl = url;
      _currentTitle = title;
    });

    _videoController = VideoPlayerController.networkUrl(Uri.parse(url));
    try {
      await _videoController!.initialize();
      if (startAt != null && startAt > Duration.zero) {
        await _videoController!.seekTo(startAt);
      }
      await _videoController!.setPlaybackSpeed(_currentSpeed);

      _chewieController = ChewieController(
        videoPlayerController: _videoController!,
        autoPlay: true,
        looping: false,
        allowFullScreen: true,
        allowPlaybackSpeedChanging: true,
        playbackSpeeds: const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0],
        showControlsOnInitialize: false,
      );
      _showOverlayControls = true;
      _scheduleControlsAutoHide();
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Playback Error: $e'), backgroundColor: Colors.redAccent),
        );
      }
      setState(() => _currentStreamUrl = null);
    }
  }

  Future<void> _openTvSpeedAndQualitySheet() async {
    _controlsTimer?.cancel();
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF16222D),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('TV Playback Speed', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              children: [0.5, 0.75, 1.0, 1.25, 1.5, 2.0].map((s) {
                final selected = _currentSpeed == s;
                return ChoiceChip(
                  label: Text('${s}x'),
                  selected: selected,
                  selectedColor: Colors.tealAccent.withOpacity(0.3),
                  onSelected: (_) {
                    Navigator.pop(ctx);
                    _setPlaybackSpeed(s);
                  },
                );
              }).toList(),
            ),
            if (_availableQualities.isNotEmpty) ...[
              const SizedBox(height: 20),
              const Text('Video Quality / Resolution', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                children: _availableQualities.map((q) {
                  final selected = _currentQualityLabel == q.label;
                  return ChoiceChip(
                    label: Text(q.label),
                    selected: selected,
                    selectedColor: Colors.cyanAccent.withOpacity(0.3),
                    onSelected: (_) {
                      Navigator.pop(ctx);
                      _switchStreamQuality(q.url, q.label);
                    },
                  );
                }).toList(),
              ),
            ],
          ],
        ),
      ),
    );
    if (mounted) {
      _revealControls();
    }
  }

  void _disposePlayer() {
    _controlsTimer?.cancel();
    _controlsTimer = null;
    _showOverlayControls = true;
    _chewieController?.dispose();
    _videoController?.dispose();
    _chewieController = null;
    _videoController = null;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _disposePlayer();
    for (var s in _sockets) {
      s.close();
    }
    _udpSocket?.close();
    _server?.close();
    _mqttClient?.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_currentStreamUrl != null && _chewieController != null) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          autofocus: true,
          onKeyEvent: (node, event) {
            _revealControls();
            return KeyEventResult.ignored;
          },
          child: MouseRegion(
            onHover: (_) => _revealControls(),
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () {
                if (_showOverlayControls) {
                  _scheduleControlsAutoHide();
                } else {
                  _revealControls();
                }
              },
              child: Stack(
                children: [
                  Center(child: Chewie(controller: _chewieController!)),
                  Positioned(
                    top: 24,
                    left: 24,
                    right: 24,
                    child: AnimatedOpacity(
                      opacity: _showOverlayControls ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 300),
                      child: IgnorePointer(
                        ignoring: !_showOverlayControls,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            ElevatedButton.icon(
                              onPressed: () {
                                _disposePlayer();
                                setState(() => _currentStreamUrl = null);
                              },
                              icon: const Icon(Icons.arrow_back),
                              label: const Text('Exit Stream'),
                            ),
                            Row(
                              children: [
                                ElevatedButton.icon(
                                  autofocus: false,
                                  onPressed: _openTvSpeedAndQualitySheet,
                                  icon: const Icon(Icons.tune, color: Colors.tealAccent),
                                  label: Text('Speed (${_currentSpeed}x) & Quality ($_currentQualityLabel)'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(_deviceName),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.tealAccent),
            tooltip: 'Refresh Network & IP',
            onPressed: () {
              _initReceiverServices();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Refreshing network & pairing details...'), duration: Duration(seconds: 1)),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.system_update, color: Colors.tealAccent),
            tooltip: 'Check GitHub for Update',
            onPressed: () => GitHubAutoUpdater.checkForUpdate(context, silentIfUpToDate: false),
          ),
          Center(
            child: Padding(
              padding: const EdgeInsets.only(right: 20, left: 8),
              child: Text(
                _mqttConnected ? 'Router-Bypass: Ready' : 'LAN Standby',
                style: TextStyle(
                  color: (_sockets.isNotEmpty || _mqttConnected) ? Colors.tealAccent : Colors.grey,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: QrImageView(
                    data: _pairingQrData,
                    version: QrVersions.auto,
                    size: 220.0,
                  ),
                ),
                const SizedBox(width: 40),
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Scan QR or Auto-Discover on Wi-Fi',
                      style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.tealAccent.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.tealAccent),
                      ),
                      child: Text(
                        'TV Pairing Code (Works on any Router): $_roomCode',
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.tealAccent),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Local Wi-Fi Address: ws://$_localIp:$kReceiverPort',
                      style: const TextStyle(fontSize: 15, color: Colors.white70),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      '• Appears automatically in your Phone Controller device list.\n'
                      '• Works even if your Wi-Fi Router has AP/Client Isolation enabled.\n'
                      '• Supports YouTube, Instagram Reels/Posts, HLS (.m3u8) & MP4.',
                      style: TextStyle(color: Colors.grey, height: 1.5),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// BACKGROUND OVERLAY POPUP
// ============================================================================
class BackgroundOverlayPrompt extends StatefulWidget {
  const BackgroundOverlayPrompt({super.key});

  @override
  State<BackgroundOverlayPrompt> createState() => _BackgroundOverlayPromptState();
}

class _BackgroundOverlayPromptState extends State<BackgroundOverlayPrompt> {
  String _incomingUrl = '';
  String _incomingTitle = 'Incoming TV Stream';

  @override
  void initState() {
    super.initState();
    FlutterOverlayWindow.overlayListener.listen((data) {
      if (data is Map && data['url'] != null) {
        setState(() {
          _incomingUrl = data['url'];
          _incomingTitle = data['title'] ?? 'Incoming TV Stream';
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.tealAccent, width: 2),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.live_tv, color: Colors.tealAccent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _incomingTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              _incomingUrl,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const Spacer(),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () async => await FlutterOverlayWindow.closeOverlay(),
                  child: const Text('Reject', style: TextStyle(color: Colors.redAccent)),
                ),
                const SizedBox(width: 12),
                ElevatedButton(
                  autofocus: true,
                  onPressed: () async {
                    await FlutterOverlayWindow.shareData({
                      'action': 'ACCEPT',
                      'url': _incomingUrl,
                      'title': _incomingTitle,
                    });
                    await FlutterOverlayWindow.closeOverlay();
                  },
                  child: const Text('Accept & Play'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// PHONE CONTROLLER MODE (Wi-Fi Device Scanner + History + YT/IG + Speed/Quality)
// ============================================================================
class ControllerScreen extends StatefulWidget {
  const ControllerScreen({super.key});

  @override
  State<ControllerScreen> createState() => _ControllerScreenState();
}

class _ControllerScreenState extends State<ControllerScreen> {
  WebSocket? _socket;
  MqttServerClient? _mqttClient;
  String? _pairedRoomCode;
  String _connectedDeviceName = '';
  bool _isConnected = false;
  bool _usingRouterBypass = false;

  bool _isScanningWifi = false;
  final Map<String, DiscoveredReceiver> _discoveredDevices = {};

  bool _isExtracting = false;
  final TextEditingController _wsAddressCtrl = TextEditingController();
  final TextEditingController _urlInputCtrl = TextEditingController();

  String _extractedTitle = '';
  List<StreamQualityOption> _extractedQualities = [];
  StreamQualityOption? _selectedQuality;
  double _selectedSpeed = 1.0;

  List<PlaybackHistoryItem> _history = [];

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _initMqttControllerBus();
    _scanWifiForReceivers();
  }

  @override
  void dispose() {
    _socket?.close();
    _mqttClient?.disconnect();
    _wsAddressCtrl.dispose();
    _urlInputCtrl.dispose();
    super.dispose();
  }

  Future<void> _initMqttControllerBus() async {
    final clientId = 'ds_ctrl_${Random().nextInt(99999)}';
    final client = MqttServerClient(kMqttBroker, clientId);
    client.port = 1883;
    client.keepAlivePeriod = 30;
    client.autoReconnect = true;
    client.logging(on: false);

    client.onConnected = () {
      client.subscribe('directstream/lan/announce', MqttQos.atMostOnce);
      _broadcastMqttDiscoveryPing();
    };

    try {
      await client.connect();
      _mqttClient = client;
      client.updates?.listen((List<MqttReceivedMessage<MqttMessage?>>? c) {
        if (c == null || c.isEmpty) return;
        final recMess = c[0].payload as MqttPublishMessage;
        final payloadStr = MqttPublishPayload.bytesToStringAsString(recMess.payload.message);
        try {
          final data = jsonDecode(payloadStr);
          if (data['app'] == 'DirectStream' && data['room'] != null) {
            final dev = DiscoveredReceiver(
              name: data['name'] ?? 'DirectStream TV',
              ip: data['ip'] ?? '',
              port: data['port'] ?? kReceiverPort,
              roomCode: data['room'],
              mode: 'Router-Bypass',
            );
            if (mounted) {
              setState(() {
                _discoveredDevices[dev.roomCode] = dev;
              });
            }
          }
        } catch (_) {}
      });
    } catch (_) {}
  }

  void _broadcastMqttDiscoveryPing() {
    if (_mqttClient?.connectionStatus?.state == MqttConnectionState.connected) {
      final builder = MqttClientPayloadBuilder();
      builder.addString('DISCOVER');
      _mqttClient!.publishMessage('directstream/lan/discover', MqttQos.atMostOnce, builder.payload!);
    }
  }

  /// Scans local Wi-Fi via UDP Broadcast + Parallel Subnet Sweep (1..254) + Router-Bypass Relay
  Future<void> _scanWifiForReceivers() async {
    if (_isScanningWifi) return;
    setState(() => _isScanningWifi = true);

    _broadcastMqttDiscoveryPing();

    // 1. UDP Broadcast discovery
    try {
      final udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      udp.broadcastEnabled = true;
      udp.listen((event) {
        if (event == RawSocketEvent.read) {
          final dg = udp.receive();
          if (dg == null) return;
          try {
            final data = jsonDecode(utf8.decode(dg.data));
            if (data['app'] == 'DirectStream') {
              final dev = DiscoveredReceiver(
                name: data['name'] ?? 'DirectStream TV',
                ip: data['ip'] ?? dg.address.address,
                port: data['port'] ?? kReceiverPort,
                roomCode: data['room'] ?? '',
                mode: 'LAN',
              );
              if (mounted) {
                setState(() {
                  _discoveredDevices[dev.roomCode.isNotEmpty ? dev.roomCode : dev.ip] = dev;
                });
              }
            }
          } catch (_) {}
        }
      });
      udp.send(utf8.encode('DIRECTSTREAM_DISCOVER'), InternetAddress('255.255.255.255'), kDiscoveryUdpPort);
      Future.delayed(const Duration(seconds: 3), () => udp.close());
    } catch (_) {}

    // 2. Parallel HTTP Subnet Sweep across local /24 Wi-Fi network
    try {
      String? myIp = await NetworkInfo().getWifiIP();
      if (myIp == null) {
        final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
        for (var iface in interfaces) {
          for (var addr in iface.addresses) {
            if (!addr.isLoopback && addr.address.startsWith('192.168.')) {
              myIp = addr.address;
              break;
            }
          }
        }
      }

      if (myIp != null && myIp.contains('.')) {
        final subnet = myIp.substring(0, myIp.lastIndexOf('.'));
        final client = http.Client();
        final List<Future<void>> probes = [];

        for (int i = 1; i <= 254; i++) {
          final targetIp = '$subnet.$i';
          probes.add(() async {
            try {
              final res = await client
                  .get(Uri.parse('http://$targetIp:$kReceiverPort/discover'))
                  .timeout(const Duration(milliseconds: 650));
              if (res.statusCode == 200) {
                final data = jsonDecode(res.body);
                if (data['app'] == 'DirectStream') {
                  final dev = DiscoveredReceiver(
                    name: data['name'] ?? 'DirectStream TV ($targetIp)',
                    ip: targetIp,
                    port: data['port'] ?? kReceiverPort,
                    roomCode: data['room'] ?? targetIp,
                    mode: 'LAN',
                  );
                  if (mounted) {
                    setState(() {
                      _discoveredDevices[dev.roomCode] = dev;
                    });
                  }
                }
              }
            } catch (_) {}
          }());
        }
        await Future.wait(probes);
        client.close();
      }
    } catch (_) {}

    if (mounted) setState(() => _isScanningWifi = false);
  }

  /// Connects to a Discovered TV or manual input. Automatically falls back to Router-Bypass Relay
  /// if the home Wi-Fi router blocks direct local sockets (AP Isolation).
  Future<void> _connectToReceiver({String? rawInput, DiscoveredReceiver? device}) async {
    String? wsCandidate;
    String? roomCandidate = device?.roomCode;
    String label = device?.name ?? '';

    if (rawInput != null && rawInput.trim().isNotEmpty) {
      final trimmed = rawInput.trim();
      // Check if JSON from QR code
      if (trimmed.startsWith('{')) {
        try {
          final parsed = jsonDecode(trimmed);
          wsCandidate = parsed['ws'];
          roomCandidate = parsed['room']?.toString();
          label = parsed['name'] ?? 'DirectStream TV';
        } catch (_) {}
      } else if (RegExp(r'^\d{6}$').hasMatch(trimmed)) {
        // 6-digit TV Room Code entered directly
        roomCandidate = trimmed;
        label = 'TV Room $trimmed';
      } else {
        wsCandidate = _normalizeWsAddress(trimmed);
        label = wsCandidate;
      }
    } else if (device != null) {
      wsCandidate = device.wsUrl;
    }

    // 1. Try Direct Low-Latency LAN WebSocket first (2.5 second timeout)
    if (wsCandidate != null && wsCandidate.isNotEmpty) {
      try {
        final ws = await WebSocket.connect(wsCandidate).timeout(const Duration(milliseconds: 2500));
        if (!mounted) return;
        setState(() {
          _socket = ws;
          _isConnected = true;
          _usingRouterBypass = false;
          _pairedRoomCode = roomCandidate;
          _connectedDeviceName = label.isNotEmpty ? label : wsCandidate!;
          _wsAddressCtrl.text = wsCandidate!;
        });
        ws.listen(
          null,
          onDone: () {
            if (mounted && !_usingRouterBypass) setState(() => _isConnected = false);
          },
          onError: (_) {
            if (mounted && !_usingRouterBypass) setState(() => _isConnected = false);
          },
        );
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Connected via LAN to $_connectedDeviceName!'), backgroundColor: Colors.teal),
        );
        return;
      } catch (_) {
        // Direct LAN failed (e.g. Router AP Isolation) -> Fall through to Router-Bypass Relay if room code is known
      }
    }

    // 2. Router AP-Isolation Bypass via MQTT Relay
    if (roomCandidate != null && roomCandidate.isNotEmpty) {
      if (_mqttClient?.connectionStatus?.state != MqttConnectionState.connected) {
        await _initMqttControllerBus();
      }
      if (_mqttClient?.connectionStatus?.state == MqttConnectionState.connected) {
        setState(() {
          _isConnected = true;
          _usingRouterBypass = true;
          _pairedRoomCode = roomCandidate;
          _connectedDeviceName = '$label (Router-Bypass)';
          _wsAddressCtrl.text = 'Room: $roomCandidate';
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Connected to $_connectedDeviceName (Router Isolation Bypassed)!'),
              backgroundColor: Colors.teal,
            ),
          );
        }
        return;
      }
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not reach TV over LAN. Enter the 6-digit TV Pairing Code or scan the QR code to bypass Router Isolation!'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  String _normalizeWsAddress(String rawInput) {
    String cleaned = rawInput.trim();
    if (!cleaned.startsWith('ws://') && !cleaned.startsWith('wss://')) {
      cleaned = 'ws://$cleaned';
    }
    final dotPortRegex = RegExp(r'^(wss?://\d+\.\d+\.\d+\.\d+)\.(\d+)$');
    final match = dotPortRegex.firstMatch(cleaned);
    if (match != null) {
      cleaned = '${match.group(1)}:${match.group(2)}';
    }
    final noPortRegex = RegExp(r'^(wss?://\d+\.\d+\.\d+\.\d+)$');
    if (noPortRegex.hasMatch(cleaned)) {
      cleaned = '$cleaned:$kReceiverPort';
    }
    return cleaned;
  }

  Future<void> _openQrScanner() async {
    final String? scannedCode = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const QrScannerPage()),
    );
    if (scannedCode != null && scannedCode.isNotEmpty && mounted) {
      await _connectToReceiver(rawInput: scannedCode);
    }
  }

  // ==========================================================================
  // STREAM EXTRACTOR (YouTube + Shorts/Live + Instagram Reels + Web/IPTV)
  // ==========================================================================

  /// Extracts the 11-character YouTube video ID from any format:
  /// watch?v=, shorts/, live/, embed/, v/, clip/, youtu.be/, or raw 11-char ID
  String? _parseYouTubeVideoId(String input) {
    final clean = input.trim();
    // 1. Standard YouTube URL patterns
    final regExp = RegExp(
      r'(?:https?:\/\/)?(?:www\.|m\.|music\.)?(?:youtube\.com\/(?:watch\?(?:.*&)?v=|embed\/|v\/|shorts\/|live\/|clip\/)|youtu\.be\/)([a-zA-Z0-9_-]{11})',
      caseSensitive: false,
    );
    final match = regExp.firstMatch(clean);
    if (match != null && match.group(1) != null) {
      return match.group(1);
    }
    // 2. Query param ?v=ID
    final vParamMatch = RegExp(r'[?&]v=([a-zA-Z0-9_-]{11})').firstMatch(clean);
    if (vParamMatch != null && vParamMatch.group(1) != null) {
      return vParamMatch.group(1);
    }
    // 3. Raw 11-char ID
    if (RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(clean)) {
      return clean;
    }
    return null;
  }

  /// Extracts direct video streams for standard VOD, Shorts, and Live streams.
  Future<List<StreamQualityOption>> _extractYouTubeStreams(String videoId) async {
    final List<StreamQualityOption> list = [];
    final ytExplode = yt.YoutubeExplode();
    final ytId = yt.VideoId(videoId);

    try {
      final video = await ytExplode.videos.get(ytId);
      _extractedTitle = video.title;

      if (video.isLive) {
        // Active Live Stream -> get HLS live stream URL (.m3u8)
        try {
          final liveUrl = await ytExplode.videos.streamsClient.getHttpLiveStreamUrl(ytId);
          if (liveUrl.isNotEmpty) {
            list.add(StreamQualityOption(
              label: 'YouTube Live (HLS)',
              url: liveUrl,
            ));
          }
        } catch (_) {}
      } else {
        // Standard VOD or Shorts -> get muxed / HLS streams
        try {
          final manifest = await ytExplode.videos.streamsClient.getManifest(ytId);
          final muxed = manifest.muxed.sortByVideoQuality();
          final Set<String> seenLabels = {};
          for (final s in muxed) {
            final label = s.qualityLabel;
            if (!seenLabels.contains(label)) {
              seenLabels.add(label);
              list.add(StreamQualityOption(label: label, url: s.url.toString()));
            }
          }
          if (manifest.hls.isNotEmpty) {
            list.add(StreamQualityOption(
              label: 'Auto (HLS)',
              url: manifest.hls.first.url.toString(),
            ));
          }
        } catch (_) {
          // If manifest throws (e.g. live stream transition), fallback to live stream URL
          try {
            final fallbackUrl = await ytExplode.videos.streamsClient.getHttpLiveStreamUrl(ytId);
            if (fallbackUrl.isNotEmpty) {
              list.add(StreamQualityOption(label: 'Live / HLS Stream', url: fallbackUrl));
            }
          } catch (_) {}
        }
      }
    } catch (_) {
      // If metadata lookup fails, try direct live stream URL as last resort
      try {
        final fallbackUrl = await ytExplode.videos.streamsClient.getHttpLiveStreamUrl(ytId);
        if (fallbackUrl.isNotEmpty) {
          _extractedTitle = 'YouTube Stream';
          list.add(StreamQualityOption(label: 'Live Stream (HLS)', url: fallbackUrl));
        }
      } catch (_) {}
    } finally {
      ytExplode.close();
    }

    return list;
  }

  /// Extracts direct MP4 video from Instagram Reels and Posts
  Future<List<StreamQualityOption>> _extractInstagramVideo(String rawInput) async {
    final List<StreamQualityOption> list = [];
    final Set<String> urls = {};

    // 1. Extract shortcode
    final scMatch = RegExp(r'instagram\.com\/(?:reel|reels|p|share\/reel)\/([a-zA-Z0-9_-]+)').firstMatch(rawInput);
    final shortcode = scMatch?.group(1);
    if (shortcode == null) return list;

    // 2. Query official web client JSON API with X-IG-App-ID
    try {
      final jsonUrl = 'https://www.instagram.com/p/$shortcode/?__a=1&__d=dis';
      final res = await http.get(
        Uri.parse(jsonUrl),
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
          'X-IG-App-ID': '936619743392459',
          'Accept': 'application/json, text/plain, */*',
        },
      ).timeout(const Duration(seconds: 6));

      if (res.statusCode == 200 && res.body.trim().startsWith('{')) {
        final data = jsonDecode(res.body);
        if (data is Map<String, dynamic>) {
          // Check items[0].video_versions
          final items = data['items'] as List?;
          if (items != null && items.isNotEmpty) {
            final firstItem = items[0] as Map<String, dynamic>?;
            final videoVersions = firstItem?['video_versions'] as List?;
            if (videoVersions != null) {
              for (final v in videoVersions) {
                final u = v['url']?.toString();
                if (u != null && !urls.contains(u)) {
                  urls.add(u);
                  final width = v['width'] ?? '';
                  final height = v['height'] ?? '';
                  final label = (width != '' && height != '')
                      ? '${width}x$height'
                      : (list.isEmpty ? 'Instagram HD' : 'Stream #${list.length + 1}');
                  list.add(StreamQualityOption(label: label, url: u));
                }
              }
            }
          }
          // Check graphql.shortcode_media.video_url
          final graphql = data['graphql'] as Map<String, dynamic>?;
          final shortcodeMedia = graphql?['shortcode_media'] as Map<String, dynamic>?;
          final videoUrl = shortcodeMedia?['video_url']?.toString();
          if (videoUrl != null && !urls.contains(videoUrl)) {
            urls.add(videoUrl);
            list.add(StreamQualityOption(
              label: list.isEmpty ? 'Instagram HD' : 'Stream #${list.length + 1}',
              url: videoUrl,
            ));
          }
        }
      }
    } catch (_) {}

    if (list.isNotEmpty) return list;

    // 3. Fallback: Parse embed captioned page
    try {
      final embedUrl = 'https://www.instagram.com/p/$shortcode/embed/captioned/';
      final res = await http.get(
        Uri.parse(embedUrl),
        headers: {
          'User-Agent':
              'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
        },
      ).timeout(const Duration(seconds: 6));

      if (res.statusCode == 200) {
        final decoded = res.body
            .replaceAll(r'\/', '/')
            .replaceAll(r'\u0026', '&')
            .replaceAll('&amp;', '&');

        final ogRegex = RegExp(r'property="og:video"\s+content="([^"]+)"');
        final jsonVideoRegex = RegExp(r'"video_url"\s*:\s*"([^"]+)"');
        final mp4Regex = RegExp(r'(https?://[^\s"<>]+\.mp4\?[^\s"<>]*)');

        for (final m in [
          ...ogRegex.allMatches(decoded),
          ...jsonVideoRegex.allMatches(decoded),
          ...mp4Regex.allMatches(decoded),
        ]) {
          final u = m.group(1);
          if (u != null && u.startsWith('http') && !urls.contains(u)) {
            urls.add(u);
            list.add(StreamQualityOption(
              label: list.isEmpty ? 'Instagram HD' : 'Stream #${list.length + 1}',
              url: u,
            ));
          }
        }
      }
    } catch (_) {}

    return list;
  }

  /// Scrapes embedded video, iframes, HTML5 video tags, and metadata from webpages
  Future<List<StreamQualityOption>> _scrapeWebpageVideos(String pageUrl) async {
    final List<StreamQualityOption> results = [];
    final Set<String> seenUrls = {};
    final baseUri = Uri.parse(pageUrl);

    try {
      final response = await http.get(
        baseUri,
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
          'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        },
      ).timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        final body = response.body;

        // 1. Page title
        final titleMatch = RegExp(r'<title[^>]*>(.*?)</title>', caseSensitive: false).firstMatch(body);
        if (titleMatch != null && titleMatch.group(1) != null) {
          _extractedTitle = titleMatch.group(1)!.trim();
        }

        // 2. Check for embedded YouTube iframe or link
        final ytEmbeddedMatch = RegExp(
          r'(?:youtube\.com\/(?:embed\/|watch\?v=)|youtu\.be\/)([a-zA-Z0-9_-]{11})',
          caseSensitive: false,
        ).firstMatch(body);
        if (ytEmbeddedMatch != null && ytEmbeddedMatch.group(1) != null) {
          final ytId = ytEmbeddedMatch.group(1)!;
          final ytStreams = await _extractYouTubeStreams(ytId);
          results.addAll(ytStreams);
        }

        // 3. OpenGraph / Twitter video meta tags
        final metaRegex = RegExp(
          r'''<meta\s+[^>]*(?:property|name)=["'](?:og:video|og:video:url|og:video:secure_url|twitter:player:stream)["']\s+content=["']([^"']+)["']''',
          caseSensitive: false,
        );
        for (final m in metaRegex.allMatches(body)) {
          final u = m.group(1);
          if (u != null && u.isNotEmpty) {
            final resolved = baseUri.resolve(u).toString();
            if (!seenUrls.contains(resolved)) {
              seenUrls.add(resolved);
              final label = resolved.contains('.m3u8') ? 'HLS Stream (Meta)' : 'Direct Video (Meta)';
              results.add(StreamQualityOption(label: label, url: resolved));
            }
          }
        }

        // 4. HTML5 <video src="..."> and <source src="..."> tags
        final tagRegex = RegExp(
          r'''<(?:video|source)\s+[^>]*src=["']([^"']+)["']''',
          caseSensitive: false,
        );
        for (final m in tagRegex.allMatches(body)) {
          final u = m.group(1);
          if (u != null && u.isNotEmpty) {
            final resolved = baseUri.resolve(u).toString();
            if (!seenUrls.contains(resolved) &&
                RegExp(r'\.(m3u8|mp4|webm|mkv|mpd)(\?.*)?$', caseSensitive: false).hasMatch(resolved)) {
              seenUrls.add(resolved);
              final label = resolved.contains('.m3u8') ? 'HLS Stream' : 'Direct Video';
              results.add(StreamQualityOption(label: '$label #${results.length + 1}', url: resolved));
            }
          }
        }

        // 5. Script / JSON embedded stream URLs
        final unescaped = body.replaceAll(r'\/', '/');
        final scriptVideoRegex = RegExp(
          r'''(https?://[^\s"'<>\\]+\.(?:m3u8|mp4|webm)(?:\?[^\s"'<>\\]*)?)''',
          caseSensitive: false,
        );
        for (final m in scriptVideoRegex.allMatches(unescaped)) {
          final u = m.group(0);
          if (u != null && !seenUrls.contains(u)) {
            seenUrls.add(u);
            final label = u.contains('.m3u8') ? 'HLS Stream #${results.length + 1}' : 'Direct MP4 #${results.length + 1}';
            results.add(StreamQualityOption(label: label, url: u));
          }
        }
      }
    } catch (_) {}

    return results;
  }

  Future<void> _extractVideoStreams(String rawUrl) async {
    // Extract first URL if pasted text contains surrounding words
    String cleanUrl = rawUrl.trim();
    final linkMatch = RegExp(r'https?://[^\s<>"]+').firstMatch(cleanUrl);
    if (linkMatch != null) {
      cleanUrl = linkMatch.group(0)!;
    }

    if (cleanUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter or paste a valid video URL.')),
      );
      return;
    }

    setState(() {
      _isExtracting = true;
      _extractedQualities = [];
      _selectedQuality = null;
      _extractedTitle = 'Extracted Video';
    });

    final List<StreamQualityOption> qualities = [];

    try {
      // 1. Check if input is a YouTube video / shorts / live / shared text
      final ytId = _parseYouTubeVideoId(rawUrl);
      if (ytId != null) {
        final ytStreams = await _extractYouTubeStreams(ytId);
        qualities.addAll(ytStreams);
      }
      // 2. Check if Instagram Reel / Post URL
      else if (cleanUrl.contains('instagram.com/')) {
        _extractedTitle = 'Instagram Video';
        final igStreams = await _extractInstagramVideo(rawUrl);
        qualities.addAll(igStreams);
      }
      // 3. Direct IPTV (.m3u8) or Direct Video Link (.mp4, .webm, .mkv, .mpd)
      else if (RegExp(r'\.(m3u8|mp4|webm|mkv|mpd)(\?.*)?$', caseSensitive: false).hasMatch(cleanUrl)) {
        final isHls = cleanUrl.toLowerCase().contains('.m3u8');
        _extractedTitle = isHls ? 'IPTV / HLS Stream' : 'Direct Video Stream';
        qualities.add(StreamQualityOption(label: isHls ? 'Auto (HLS)' : 'Original HD', url: cleanUrl));

        // If master .m3u8 playlist, parse resolution variants (1080p, 720p, 480p)
        if (isHls) {
          final variants = await _parseHlsMasterVariants(cleanUrl);
          qualities.addAll(variants);
        }
      }
      // 4. Generic Webpage Scraper (Extracts embedded YouTube, HTML5 video, og:video)
      else {
        final webStreams = await _scrapeWebpageVideos(cleanUrl);
        qualities.addAll(webStreams);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Extraction notice: $e')),
        );
      }
    }

    setState(() {
      _extractedQualities = qualities;
      if (qualities.isNotEmpty) {
        _selectedQuality = qualities.first;
      }
      _isExtracting = false;
    });

    if (mounted) {
      if (qualities.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No playable streams found. Verify the URL or ensure the video is public.'),
            backgroundColor: Colors.orangeAccent,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Found ${qualities.length} stream quality option(s)! Ready to cast.'),
            backgroundColor: Colors.teal,
          ),
        );
      }
    }
  }

  Future<List<StreamQualityOption>> _parseHlsMasterVariants(String masterUrl) async {
    final List<StreamQualityOption> variants = [];
    try {
      final res = await http.get(Uri.parse(masterUrl)).timeout(const Duration(seconds: 4));
      if (res.statusCode == 200 && res.body.contains('#EXT-X-STREAM-INF')) {
        final lines = res.body.split('\n');
        final baseUri = Uri.parse(masterUrl);
        for (int i = 0; i < lines.length; i++) {
          final line = lines[i].trim();
          if (line.startsWith('#EXT-X-STREAM-INF')) {
            String label = 'Variant';
            final resMatch = RegExp(r'RESOLUTION=\d+x(\d+)').firstMatch(line);
            if (resMatch != null) {
              label = '${resMatch.group(1)}p';
            }
            if (i + 1 < lines.length) {
              final nextLine = lines[i + 1].trim();
              if (nextLine.isNotEmpty && !nextLine.startsWith('#')) {
                final resolvedUrl = baseUri.resolve(nextLine).toString();
                variants.add(StreamQualityOption(label: label, url: resolvedUrl));
              }
            }
          }
        }
      }
    } catch (_) {}
    return variants;
  }

  // ==========================================================================
  // PLAYBACK HISTORY STORAGE (SharedPreferences)
  // ==========================================================================
  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> rawList = prefs.getStringList('playback_history_v4') ?? [];
    setState(() {
      _history = rawList
          .map((item) => PlaybackHistoryItem.fromJson(jsonDecode(item)))
          .toList();
    });
  }

  Future<void> _saveToHistory({
    required String title,
    required String originalUrl,
    required String streamUrl,
    required List<StreamQualityOption> qualities,
  }) async {
    final now = DateTime.now();
    final timeStr =
        '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    final newItem = PlaybackHistoryItem(
      title: title,
      originalUrl: originalUrl,
      streamUrl: streamUrl,
      qualities: qualities,
      timestamp: timeStr,
    );

    _history.removeWhere((h) => h.streamUrl == streamUrl || (originalUrl.isNotEmpty && h.originalUrl == originalUrl));
    _history.insert(0, newItem);
    if (_history.length > 40) {
      _history = _history.sublist(0, 40);
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'playback_history_v4',
      _history.map((h) => jsonEncode(h.toJson())).toList(),
    );
    if (mounted) setState(() {});
  }

  void _openHistoryModal() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF16222D),
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.65,
        maxChildSize: 0.9,
        builder: (_, scrollCtrl) => Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.history, color: Colors.tealAccent),
                      SizedBox(width: 8),
                      Text('Playback History', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  if (_history.isNotEmpty)
                    TextButton.icon(
                      onPressed: () async {
                        final prefs = await SharedPreferences.getInstance();
                        await prefs.remove('playback_history_v4');
                        setState(() => _history.clear());
                        if (ctx.mounted) Navigator.pop(ctx);
                      },
                      icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 18),
                      label: const Text('Clear All', style: TextStyle(color: Colors.redAccent)),
                    ),
                ],
              ),
              const Divider(color: Colors.white24),
              Expanded(
                child: _history.isEmpty
                    ? const Center(
                        child: Text('No videos played yet. Cast a stream to save it here!',
                            style: TextStyle(color: Colors.grey)),
                      )
                    : ListView.builder(
                        controller: scrollCtrl,
                        itemCount: _history.length,
                        itemBuilder: (_, idx) {
                          final item = _history[idx];
                          return Card(
                            margin: const EdgeInsets.only(bottom: 8),
                            child: ListTile(
                              leading: const Icon(Icons.play_circle_fill, color: Colors.tealAccent, size: 34),
                              title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text('${item.timestamp} • ${item.originalUrl}',
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                              trailing: ElevatedButton(
                                onPressed: () {
                                  Navigator.pop(ctx);
                                  setState(() {
                                    _extractedTitle = item.title;
                                    _extractedQualities = item.qualities.isNotEmpty
                                        ? item.qualities
                                        : [StreamQualityOption(label: 'Auto', url: item.streamUrl)];
                                    _selectedQuality = _extractedQualities.first;
                                  });
                                  _castStreamToTv(
                                    streamUrl: item.streamUrl,
                                    title: item.title,
                                    originalUrl: item.originalUrl,
                                    qualities: _extractedQualities,
                                    qualityLabel: _extractedQualities.first.label,
                                  );
                                },
                                child: const Text('Play on TV'),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ==========================================================================
  // SEND COMMANDS TO TV (LAN WebSocket OR Router-Bypass MQTT Relay)
  // ==========================================================================
  void _sendPayload(Map<String, dynamic> data) {
    if (!_isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select or connect to a DirectStream TV first!')),
      );
      return;
    }

    final encoded = jsonEncode(data);
    if (!_usingRouterBypass && _socket != null) {
      _socket!.add(encoded);
    } else if (_pairedRoomCode != null &&
        _mqttClient?.connectionStatus?.state == MqttConnectionState.connected) {
      final builder = MqttClientPayloadBuilder();
      builder.addString(encoded);
      _mqttClient!.publishMessage(
        'directstream/room/$_pairedRoomCode/cmd',
        MqttQos.atLeastOnce,
        builder.payload!,
      );
    }
  }

  void _castStreamToTv({
    required String streamUrl,
    required String title,
    required String originalUrl,
    required List<StreamQualityOption> qualities,
    required String qualityLabel,
  }) {
    _sendPayload({
      'command': 'PLAY',
      'url': streamUrl,
      'title': title,
      'qualityLabel': qualityLabel,
      'qualities': qualities.map((q) => q.toJson()).toList(),
    });

    _saveToHistory(
      title: title,
      originalUrl: originalUrl,
      streamUrl: streamUrl,
      qualities: qualities,
    );
  }

  @override
  Widget build(BuildContext context) {
    final devicesList = _discoveredDevices.values.toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Phone Controller'),
        actions: [
          IconButton(
            icon: const Icon(Icons.history, color: Colors.cyanAccent),
            tooltip: 'Playback History',
            onPressed: _openHistoryModal,
          ),
          IconButton(
            icon: const Icon(Icons.system_update, color: Colors.tealAccent),
            tooltip: 'Check GitHub Update',
            onPressed: () => GitHubAutoUpdater.checkForUpdate(context, silentIfUpToDate: false),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 14, left: 4),
            child: Icon(
              _isConnected ? Icons.cast_connected : Icons.cast,
              color: _isConnected ? Colors.tealAccent : Colors.grey,
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 1. AUTO-DISCOVERED WIFI RECEIVERS + PAIRING CARD
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          _isConnected
                              ? 'Connected: $_connectedDeviceName'
                              : 'Step 1: Select DirectStream TV on Wi-Fi',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            color: _isConnected ? Colors.tealAccent : Colors.white,
                          ),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _isScanningWifi ? null : _scanWifiForReceivers,
                        icon: _isScanningWifi
                            ? const SizedBox(
                                width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.wifi_find, size: 18),
                        label: Text(_isScanningWifi ? 'Scanning...' : 'Scan Wi-Fi'),
                      ),
                    ],
                  ),
                  if (devicesList.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    ...devicesList.map((dev) => Container(
                          margin: const EdgeInsets.only(bottom: 6),
                          decoration: BoxDecoration(
                            color: Colors.tealAccent.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.tealAccent.withOpacity(0.3)),
                          ),
                          child: ListTile(
                            dense: true,
                            leading: const Icon(Icons.tv, color: Colors.tealAccent),
                            title: Text(dev.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                            subtitle: Text('IP: ${dev.ip} • Room Code: ${dev.roomCode} (${dev.mode})'),
                            trailing: ElevatedButton(
                              onPressed: () => _connectToReceiver(device: dev),
                              child: const Text('Pair'),
                            ),
                          ),
                        )),
                  ] else if (!_isScanningWifi) ...[
                    const Padding(
                      padding: EdgeInsets.only(bottom: 10),
                      child: Text(
                        'No TV found on subnet yet. Tap "Scan Wi-Fi", scan the TV QR code, or enter the 6-digit TV Room Code below:',
                        style: TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _wsAddressCtrl,
                          decoration: const InputDecoration(
                            labelText: '6-Digit Room Code or TV IP',
                            hintText: 'e.g. 482910 or ws://192.168.1.39:8080',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: () => _connectToReceiver(rawInput: _wsAddressCtrl.text),
                        child: const Text('Connect'),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filledTonal(
                        onPressed: _openQrScanner,
                        icon: const Icon(Icons.qr_code_scanner),
                        tooltip: 'Scan QR Code',
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // 2. YOUTUBE / INSTAGRAM / IPTV / WEB EXTRACTOR CARD
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Expanded(
                        child: Text(
                          'Step 2: YouTube, Instagram, IPTV or Web URL',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _openHistoryModal,
                        icon: const Icon(Icons.history, size: 18, color: Colors.cyanAccent),
                        label: Text('History (${_history.length})',
                            style: const TextStyle(color: Colors.cyanAccent)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _urlInputCtrl,
                    decoration: InputDecoration(
                      hintText: 'Paste YouTube, Instagram Reel, .m3u8 or Web link',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () => _urlInputCtrl.clear(),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _isExtracting ? null : () => _extractVideoStreams(_urlInputCtrl.text),
                      icon: _isExtracting
                          ? const SizedBox(
                              width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.bolt),
                      label: Text(_isExtracting ? 'Extracting Qualities...' : 'Extract Ad-Free Video Stream'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // 3. REMOTE PLAYBACK, SPEED & QUALITY CONTROLS
          if (_isConnected || _extractedQualities.isNotEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Step 3: Playback, Speed & Quality Controls',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        ElevatedButton.icon(
                          onPressed: () => _sendPayload({'command': 'RESUME'}),
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('Play'),
                        ),
                        ElevatedButton.icon(
                          onPressed: () => _sendPayload({'command': 'PAUSE'}),
                          icon: const Icon(Icons.pause),
                          label: const Text('Pause'),
                        ),
                        ElevatedButton.icon(
                          onPressed: () => _sendPayload({'command': 'STOP'}),
                          icon: const Icon(Icons.stop),
                          label: const Text('Stop'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<double>(
                            value: _selectedSpeed,
                            decoration: const InputDecoration(
                              labelText: 'Playback Speed',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                            items: const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
                                .map((s) => DropdownMenuItem(value: s, child: Text('${s}x Speed')))
                                .toList(),
                            onChanged: (val) {
                              if (val == null) return;
                              setState(() => _selectedSpeed = val);
                              _sendPayload({'command': 'SPEED', 'speed': val});
                            },
                          ),
                        ),
                        const SizedBox(width: 12),
                        if (_extractedQualities.isNotEmpty)
                          Expanded(
                            child: DropdownButtonFormField<StreamQualityOption>(
                              value: _selectedQuality,
                              decoration: const InputDecoration(
                                labelText: 'Stream Quality',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              items: _extractedQualities
                                  .map((q) => DropdownMenuItem(value: q, child: Text(q.label)))
                                  .toList(),
                              onChanged: (q) {
                                if (q == null) return;
                                setState(() => _selectedQuality = q);
                                _sendPayload({
                                  'command': 'QUALITY',
                                  'url': q.url,
                                  'qualityLabel': q.label,
                                });
                              },
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

          const SizedBox(height: 16),
          if (_extractedQualities.isNotEmpty) ...[
            Text(
              'Ready to Cast: $_extractedTitle',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.tealAccent),
            ),
            const SizedBox(height: 8),
            ..._extractedQualities.map(
              (q) => Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: const Icon(Icons.hd, color: Colors.tealAccent, size: 32),
                  title: Text('Quality: ${q.label}', style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text(q.url, maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: ElevatedButton.icon(
                    onPressed: () {
                      setState(() => _selectedQuality = q);
                      _castStreamToTv(
                        streamUrl: q.url,
                        title: _extractedTitle,
                        originalUrl: _urlInputCtrl.text.trim(),
                        qualities: _extractedQualities,
                        qualityLabel: q.label,
                      );
                    },
                    icon: const Icon(Icons.cast),
                    label: const Text('Cast Now'),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ============================================================================
// QR SCANNER PAGE (Single-Scan Lock)
// ============================================================================
class QrScannerPage extends StatefulWidget {
  const QrScannerPage({super.key});

  @override
  State<QrScannerPage> createState() => _QrScannerPageState();
}

class _QrScannerPageState extends State<QrScannerPage> {
  final MobileScannerController _scannerController = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _hasScanned = false;

  @override
  void dispose() {
    _scannerController.dispose();
    super.dispose();
  }

  void _onBarcodeDetected(BarcodeCapture capture) {
    if (_hasScanned) return;
    for (final barcode in capture.barcodes) {
      final String? code = barcode.rawValue;
      if (code != null && (code.startsWith('ws://') || code.startsWith('{'))) {
        _hasScanned = true;
        _scannerController.stop();
        if (mounted) {
          Navigator.of(context).pop(code);
        }
        break;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan TV QR Code'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _scannerController,
            onDetect: _onBarcodeDetected,
          ),
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.tealAccent, width: 3),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
