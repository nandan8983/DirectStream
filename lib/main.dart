import 'dart:async';
import 'dart:convert';
import 'dart:io';
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

const String kGithubRepo = 'nandan8983/DirectStream';

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
// GITHUB AUTO-UPDATER SERVICE (Checks nandan8983/DirectStream Releases)
// ============================================================================
class GitHubAutoUpdater {
  static Future<void> checkForUpdate(BuildContext context, {bool silentIfUpToDate = true}) async {
    try {
      final PackageInfo packageInfo = await PackageInfo.fromPlatform();
      final int currentBuild = int.tryParse(packageInfo.buildNumber) ?? 1;
      final String currentVersion = packageInfo.version;

      final response = await http.get(
        Uri.parse('https://api.github.com/repos/$kGithubRepo/releases/latest'),
        headers: {'Accept': 'application/vnd.github.v3+json'},
      ).timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) {
        if (!silentIfUpToDate && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No newer GitHub release found yet.')),
          );
        }
        return;
      }

      final Map<String, dynamic> release = jsonDecode(response.body);
      final String tagName = (release['tag_name'] ?? '').toString(); // e.g. "v0.0.4+4" or "v0.0.3-build5"
      final String releaseNotes = (release['body'] ?? 'New version compiled via GitHub Actions.').toString();

      // Extract build number from tag (format: v0.0.3+4 or v0.0.3-4)
      int remoteBuild = currentBuild;
      final RegExp buildRegex = RegExp(r'[+\-](\d+)$');
      final Match? buildMatch = buildRegex.firstMatch(tagName);
      if (buildMatch != null) {
        remoteBuild = int.tryParse(buildMatch.group(1)!) ?? currentBuild;
      }

      final bool hasNewerBuild = remoteBuild > currentBuild ||
          (tagName.isNotEmpty && !tagName.contains(currentVersion) && remoteBuild >= currentBuild);

      if (!hasNewerBuild) {
        if (!silentIfUpToDate && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('You are on the latest version (v$currentVersion+$currentBuild).')),
          );
        }
        return;
      }

      // Find the .apk asset download URL inside the latest GitHub Release
      String? apkDownloadUrl;
      final List<dynamic> assets = release['assets'] ?? [];
      for (final asset in assets) {
        final String name = (asset['name'] ?? '').toString();
        if (name.endsWith('.apk')) {
          apkDownloadUrl = asset['browser_download_url'];
          break;
        }
      }

      if (apkDownloadUrl != null && context.mounted) {
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
              Text('Installed: $currentVersion', style: const TextStyle(color: Colors.grey, fontSize: 13)),
              const SizedBox(height: 8),
              Text(notes, maxLines: 4, overflow: TextOverflow.ellipsis),
              if (isDownloading) ...[
                const SizedBox(height: 20),
                LinearProgressIndicator(value: progress > 0 ? progress : null, color: Colors.tealAccent),
                const SizedBox(height: 8),
                Text(statusText, style: const TextStyle(fontSize: 13, color: Colors.tealAccent)),
              ],
            ],
          ),
          actions: [
            if (!isDownloading)
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Later', style: TextStyle(color: Colors.grey)),
              ),
            ElevatedButton.icon(
              autofocus: true,
              onPressed: isDownloading
                  ? null
                  : () async {
                      setDialogState(() {
                        isDownloading = true;
                        statusText = 'Downloading APK from GitHub...';
                      });
                      try {
                        final req = http.Request('GET', Uri.parse(apkUrl));
                        final streamedRes = await http.Client().send(req);
                        final totalBytes = streamedRes.contentLength ?? 0;
                        int receivedBytes = 0;

                        final dir = await getTemporaryDirectory();
                        final apkFile = File('${dir.path}/DirectStream-update.apk');
                        final sink = apkFile.openWrite();

                        await for (final chunk in streamedRes.stream) {
                          receivedBytes += chunk.length;
                          sink.add(chunk);
                          if (totalBytes > 0) {
                            setDialogState(() {
                              progress = receivedBytes / totalBytes;
                              statusText =
                                  'Downloading: ${(progress * 100).toStringAsFixed(0)}%';
                            });
                          }
                        }
                        await sink.close();

                        setDialogState(() {
                          statusText = 'Launching installer...';
                        });
                        if (ctx.mounted) Navigator.pop(ctx);
                        await OpenFilex.open(apkFile.path);
                      } catch (e) {
                        setDialogState(() {
                          isDownloading = false;
                          statusText = 'Download failed: $e';
                        });
                      }
                    },
              icon: const Icon(Icons.download),
              label: Text(isDownloading ? 'Updating...' : 'Update Now'),
            ),
          ],
        ),
      ),
    );
  }
}

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
  String _versionLabel = 'v0.0.3';

  @override
  void initState() {
    super.initState();
    _loadPackageVersion();
    // Automatically check GitHub Releases on launch
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
                // Custom App Logo Widget
                Container(
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(
                    color: const Color(0xFF16222D),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: Colors.tealAccent.withOpacity(0.5), width: 2),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.tealAccent.withOpacity(0.15),
                        blurRadius: 20,
                        spreadRadius: 2,
                      ),
                    ],
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
                  'GitHub Auto-Update Enabled • $_versionLabel',
                  style: const TextStyle(color: Colors.tealAccent, fontSize: 13),
                ),
                const SizedBox(height: 32),
                _RoleCard(
                  autofocus: true,
                  icon: Icons.tv,
                  title: 'TV Receiver Mode',
                  subtitle: 'Displays QR code, listens in background & plays streams',
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
                  subtitle: 'Extracts embedded/IPTV URLs and casts to TV',
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

class TvReceiverScreen extends StatefulWidget {
  const TvReceiverScreen({super.key});

  @override
  State<TvReceiverScreen> createState() => _TvReceiverScreenState();
}

class _TvReceiverScreenState extends State<TvReceiverScreen> with WidgetsBindingObserver {
  HttpServer? _server;
  final List<WebSocket> _sockets = [];
  String _pairingAddress = 'Fetching IP...';
  bool _isForeground = true;
  final int _port = 8080;

  VideoPlayerController? _videoController;
  ChewieController? _chewieController;
  String? _currentStreamUrl;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initReceiverServer();
    _listenToOverlayEvents();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isForeground = (state == AppLifecycleState.resumed);
  }

  Future<void> _initReceiverServer() async {
    final bool hasOverlayPerm = await FlutterOverlayWindow.isPermissionGranted();
    if (!hasOverlayPerm) {
      await FlutterOverlayWindow.requestPermission();
    }

    final info = NetworkInfo();
    String? wifiIp = await info.getWifiIP();

    if (wifiIp == null) {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (var interface in interfaces) {
        for (var addr in interface.addresses) {
          if (!addr.isLoopback) {
            wifiIp = addr.address;
            break;
          }
        }
      }
    }

    _server = await HttpServer.bind(InternetAddress.anyIPv4, _port);
    setState(() {
      _pairingAddress = 'ws://${wifiIp ?? "127.0.0.1"}:$_port';
    });

    _server!.transform(WebSocketTransformer()).listen((WebSocket ws) {
      _sockets.add(ws);
      setState(() {});
      ws.listen(
        (data) => _handleControllerPayload(jsonDecode(data)),
        onDone: () {
          _sockets.remove(ws);
          if (mounted) setState(() {});
        },
      );
    });
  }

  void _listenToOverlayEvents() {
    FlutterOverlayWindow.overlayListener.listen((event) {
      if (event is Map && event['action'] == 'ACCEPT') {
        _startVideoPlayback(event['url']);
      }
    });
  }

  Future<void> _handleControllerPayload(Map<String, dynamic> payload) async {
    final String cmd = payload['command'] ?? '';
    final String? url = payload['url'];

    if (cmd == 'PLAY' && url != null) {
      if (_isForeground) {
        _startVideoPlayback(url);
      } else {
        final bool canOverlay = await FlutterOverlayWindow.isPermissionGranted();
        if (canOverlay) {
          await FlutterOverlayWindow.showOverlay(
            enableDrag: false,
            height: 280,
            width: 550,
            alignment: OverlayAlignment.bottomRight,
          );
          await FlutterOverlayWindow.shareData({'url': url});
        } else {
          _showAcceptRejectDialog(url);
        }
      }
    } else if (cmd == 'PAUSE') {
      _videoController?.pause();
    } else if (cmd == 'RESUME') {
      _videoController?.play();
    } else if (cmd == 'STOP') {
      _disposePlayer();
      setState(() => _currentStreamUrl = null);
    }
  }

  void _showAcceptRejectDialog(String url) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Incoming Stream Request'),
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
              _startVideoPlayback(url);
            },
            child: const Text('Accept & Play'),
          ),
        ],
      ),
    );
  }

  Future<void> _startVideoPlayback(String url) async {
    _disposePlayer();
    setState(() => _currentStreamUrl = url);

    _videoController = VideoPlayerController.networkUrl(Uri.parse(url));
    try {
      await _videoController!.initialize();
      _chewieController = ChewieController(
        videoPlayerController: _videoController!,
        autoPlay: true,
        looping: false,
        allowFullScreen: true,
        showControlsOnInitialize: false,
      );
      setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Playback Error: $e'), backgroundColor: Colors.redAccent),
        );
      }
      setState(() => _currentStreamUrl = null);
    }
  }

  void _disposePlayer() {
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
    _server?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_currentStreamUrl != null && _chewieController != null) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            Center(child: Chewie(controller: _chewieController!)),
            Positioned(
              top: 24,
              left: 24,
              child: ElevatedButton.icon(
                onPressed: () {
                  _disposePlayer();
                  setState(() => _currentStreamUrl = null);
                },
                icon: const Icon(Icons.arrow_back),
                label: const Text('Exit Stream'),
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('TV Receiver Standby'),
        actions: [
          IconButton(
            icon: const Icon(Icons.system_update, color: Colors.tealAccent),
            tooltip: 'Check GitHub for Update',
            onPressed: () => GitHubAutoUpdater.checkForUpdate(context, silentIfUpToDate: false),
          ),
          Center(
            child: Padding(
              padding: const EdgeInsets.only(right: 20, left: 8),
              child: Text(
                'Connected: ${_sockets.length}',
                style: TextStyle(
                  color: _sockets.isNotEmpty ? Colors.tealAccent : Colors.grey,
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
                  data: _pairingAddress,
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
                    'Scan with Controller App',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Manual Server URL: $_pairingAddress',
                    style: const TextStyle(fontSize: 16, color: Colors.tealAccent),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    '• While this screen is open, streams play immediately.\n'
                    '• When minimized, incoming streams trigger an Accept/Reject popup.',
                    style: TextStyle(color: Colors.grey, height: 1.5),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class BackgroundOverlayPrompt extends StatefulWidget {
  const BackgroundOverlayPrompt({super.key});

  @override
  State<BackgroundOverlayPrompt> createState() => _BackgroundOverlayPromptState();
}

class _BackgroundOverlayPromptState extends State<BackgroundOverlayPrompt> {
  String _incomingUrl = '';

  @override
  void initState() {
    super.initState();
    FlutterOverlayWindow.overlayListener.listen((data) {
      if (data is Map && data['url'] != null) {
        setState(() => _incomingUrl = data['url']);
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
            const Row(
              children: [
                Icon(Icons.live_tv, color: Colors.tealAccent),
                SizedBox(width: 10),
                Text(
                  'Incoming TV Stream',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
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
                    await FlutterOverlayWindow.shareData({'action': 'ACCEPT', 'url': _incomingUrl});
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

class ControllerScreen extends StatefulWidget {
  const ControllerScreen({super.key});

  @override
  State<ControllerScreen> createState() => _ControllerScreenState();
}

class _ControllerScreenState extends State<ControllerScreen> {
  WebSocket? _socket;
  bool _isConnected = false;
  bool _isExtracting = false;

  final TextEditingController _wsAddressCtrl = TextEditingController(text: 'ws://192.168.1.');
  final TextEditingController _urlInputCtrl = TextEditingController();
  List<String> _extractedStreams = [];

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
      cleaned = '$cleaned:8080';
    }
    return cleaned;
  }

  Future<void> _connectToTv(String rawWsUrl) async {
    final wsUrl = _normalizeWsAddress(rawWsUrl);
    setState(() {
      _wsAddressCtrl.text = wsUrl;
    });

    try {
      final ws = await WebSocket.connect(wsUrl).timeout(const Duration(seconds: 5));
      if (!mounted) return;
      setState(() {
        _socket = ws;
        _isConnected = true;
      });
      ws.listen(
        null,
        onDone: () {
          if (mounted) setState(() => _isConnected = false);
        },
        onError: (_) {
          if (mounted) setState(() => _isConnected = false);
        },
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Paired with TV Receiver ($wsUrl)!'), backgroundColor: Colors.teal),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Connection failed: $e'), backgroundColor: Colors.redAccent),
        );
      }
    }
  }

  Future<void> _openQrScanner() async {
    final String? scannedCode = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => const QrScannerPage(),
      ),
    );

    if (scannedCode != null && scannedCode.isNotEmpty && mounted) {
      await _connectToTv(scannedCode);
    }
  }

  Future<void> _extractVideoStreams(String rawUrl) async {
    final cleanUrl = rawUrl.trim();
    if (cleanUrl.isEmpty) return;

    setState(() {
      _isExtracting = true;
      _extractedStreams = [];
    });

    final Set<String> results = {};

    final directStreamRegex = RegExp(r'\.(m3u8|mp4|webm|mkv|mpd)(\?.*)?$', caseSensitive: false);
    if (directStreamRegex.hasMatch(cleanUrl)) {
      results.add(cleanUrl);
    } else {
      try {
        final response = await http.get(
          Uri.parse(cleanUrl),
          headers: {
            'User-Agent':
                'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Mobile Safari/537.36',
          },
        );

        if (response.statusCode == 200) {
          final body = response.body.replaceAll(r'\/', '/');
          final urlRegex = RegExp(
            r'''(https?://[^\s"'<>\\]+\.(?:m3u8|mp4|webm)(?:\?[^\s"'<>\\]*)?)''',
            caseSensitive: false,
          );
          for (final match in urlRegex.allMatches(body)) {
            if (match.group(0) != null) {
              results.add(match.group(0)!);
            }
          }
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Scrape error: $e')),
          );
        }
      }
    }

    setState(() {
      _extractedStreams = results.toList();
      _isExtracting = false;
    });
  }

  void _sendCommand(String command, {String? streamUrl}) {
    if (!_isConnected || _socket == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pair with TV first!')),
      );
      return;
    }
    _socket!.add(jsonEncode({
      'command': command,
      if (streamUrl != null) 'url': streamUrl,
    }));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Phone Controller'),
        actions: [
          IconButton(
            icon: const Icon(Icons.system_update, color: Colors.tealAccent),
            tooltip: 'Check GitHub Update',
            onPressed: () => GitHubAutoUpdater.checkForUpdate(context, silentIfUpToDate: false),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 16, left: 4),
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
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _isConnected ? 'Status: Paired with TV' : 'Step 1: Pair with TV Receiver',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _wsAddressCtrl,
                          decoration: const InputDecoration(
                            labelText: 'TV WebSocket IP (e.g. ws://192.168.1.39:8080)',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: () => _connectToTv(_wsAddressCtrl.text),
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
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Step 2: Paste Video Page or IPTV (.m3u8) URL',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _urlInputCtrl,
                    decoration: InputDecoration(
                      hintText: 'https://example.com/watch or .m3u8 link',
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
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.radar),
                      label: Text(_isExtracting ? 'Scraping Streams...' : 'Extract Direct Video Stream'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (_isConnected)
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ElevatedButton.icon(
                      onPressed: () => _sendCommand('RESUME'),
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Play'),
                    ),
                    ElevatedButton.icon(
                      onPressed: () => _sendCommand('PAUSE'),
                      icon: const Icon(Icons.pause),
                      label: const Text('Pause'),
                    ),
                    ElevatedButton.icon(
                      onPressed: () => _sendCommand('STOP'),
                      icon: const Icon(Icons.stop),
                      label: const Text('Stop'),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 16),
          if (_extractedStreams.isNotEmpty)
            const Text(
              'Extracted Ad-Free Streams (Tap to Play on TV):',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
            ),
          const SizedBox(height: 8),
          ..._extractedStreams.map(
            (streamUrl) => Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: const Icon(Icons.play_circle_fill, color: Colors.tealAccent, size: 32),
                title: Text(
                  streamUrl.contains('.m3u8') ? 'HLS / IPTV Stream (.m3u8)' : 'Direct Video Stream',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text(streamUrl, maxLines: 2, overflow: TextOverflow.ellipsis),
                trailing: ElevatedButton(
                  onPressed: () => _sendCommand('PLAY', streamUrl: streamUrl),
                  child: const Text('Cast Now'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

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
      if (code != null && code.startsWith('ws://')) {
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
