import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as html_parser;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await TelegramService.init();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'EzyTel Pro',
      debugShowCheckedModeBanner: false,
      theme: _liquidGlassTheme(),
      home: const HomeScreen(),
    );
  }

  ThemeData _liquidGlassTheme() {
    return ThemeData(
      brightness: Brightness.dark,
      primaryColor: Colors.purple, // تغییر به بنفش
      scaffoldBackgroundColor: Colors.black,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w600),
      ),
      cardTheme: CardThemeData(
        color: Colors.grey[900]!.withOpacity(0.4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.grey[900]!.withOpacity(0.4),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(30), borderSide: BorderSide.none),
        hintStyle: const TextStyle(color: Colors.grey),
      ),
      listTileTheme: const ListTileThemeData(
        selectedColor: Colors.purple,
        selectedTileColor: Colors.purpleAccent,
      ),
      useMaterial3: true,
    );
  }
}

// ========================== سرویس ==========================
class TelegramService {
  static late Directory cacheDir;
  static const List<String> googleDomains = [
    'www.google.com',
    'safebrowsing.google.com',
    'images.google.com',
    'maps.google.com',
    'news.google.com',
    'scholar.google.com',
    'meet.google.com',
    'mail.google.com',
    'drive.google.com',
  ];
  static final Random _random = Random();
  static late SharedPreferences _prefs;

  static Future<void> init() async {
    final appDir = await getApplicationDocumentsDirectory();
    cacheDir = Directory('${appDir.path}/telegram_cache');
    if (!await cacheDir.exists()) await cacheDir.create(recursive: true);
    _prefs = await SharedPreferences.getInstance();
  }

  static String _pickRandomDomain() => googleDomains[_random.nextInt(googleDomains.length)];

  static Future<String?> _fetchFromTelegram(String params) async {
    final domain = _pickRandomDomain();
    String url = 'https://$domain/s/$params';
    url += url.contains('?') ? '&' : '?';
    url += '_x_tr_sl=el&_x_tr_tl=en&_x_tr_hl=en&_x_tr_pto=wapp';
    try {
      final response = await http.get(Uri.parse(url), headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        'Pragma': 'no-cache',
        'Cache-Control': 'no-cache',
      });
      if (response.statusCode == 200) return response.body;
      return null;
    } catch (e) {
      return null;
    }
  }

  static Future<Map<String, dynamic>?> _fetchFromGitHub(String chid) async {
    final url = 'https://raw.githubusercontent.com/ircfspace/teleFeed/refs/heads/export/${chid.toLowerCase()}.json';
    try {
      final response = await http.get(Uri.parse(url), headers: {'User-Agent': 'EzyTel-Pro/1.0'});
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data != null && data['posts'] != null) return data;
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  static Future<Map<String, dynamic>> fetchChannelInfo(String chid) async {
    final html = await _fetchFromTelegram(chid);
    if (html != null && html.contains('<meta property="og:title"')) {
      return _parseChannelInfoFromHtml(chid, html);
    }
    final githubData = await _fetchFromGitHub(chid);
    if (githubData != null) {
      return _convertGitHubToChannelInfo(chid, githubData);
    }
    throw Exception('Channel not accessible via any source');
  }

  static Future<String> fetchMessagesHtml(String chid, {String? before}) async {
    String params = chid;
    if (before != null && before.isNotEmpty && before != '0') params = '$chid?before=$before';
    final html = await _fetchFromTelegram(params);
    if (html != null && !html.startsWith('ERROR') && html.contains('</main>')) {
      return _processTelegramHtml(chid, html, before: before);
    }
    final githubData = await _fetchFromGitHub(chid);
    if (githubData != null && githubData['posts'] != null) {
      return _convertGitHubToHtml(githubData);
    }
    throw Exception('Failed to load messages from all sources');
  }

  static Future<String> _processTelegramHtml(String chid, String html, {String? before}) async {
    String processedHtml = html;
    final imgRegex = RegExp(r'<img\s+[^>]*src="https://([^"]+)"');
    for (final match in imgRegex.allMatches(processedHtml)) {
      final fullTag = match.group(0)!;
      final imgUrl = match.group(1)!;
      final hash = _md5(imgUrl);
      final filename = '$hash.jpg';
      await _downloadImage('https://$imgUrl', filename);
      final localPath = '${cacheDir.path}/$filename';
      processedHtml = processedHtml.replaceFirst(fullTag, fullTag.replaceFirst('https://$imgUrl', localPath));
    }

    final timeRegex = RegExp(r'<time datetime="([^"]+)"');
    for (final match in timeRegex.allMatches(processedHtml)) {
      final dtStr = match.group(1)!;
      final dt = DateTime.parse(dtStr);
      final persianDate = _toPersianDate(dt);
      processedHtml = processedHtml.replaceFirst(
        RegExp(r'<time[^>]*>.*?</time>', dotAll: true),
        '<span style="color:#888;font-size:12px;">$persianDate</span>',
      );
    }

    final headerEnd = processedHtml.indexOf('</header>');
    final mainEnd = processedHtml.indexOf('</main>');
    if (headerEnd == -1 || mainEnd == -1) throw Exception('Invalid structure');
    String content = processedHtml.substring(headerEnd + 9, mainEnd + 7);

    final moreMatch = RegExp(r'data-before="([^"]+)"').firstMatch(content);
    if (moreMatch != null) {
      final beforeValue = moreMatch.group(1)!;
      content = content.replaceAllMapped(
        RegExp(r'<a[^>]*messages_more_wrap[^>]*>.*?</a>', dotAll: true),
        (_) => '<button onclick="load_more($beforeValue,\'$chid\',this)" style="background:#8A2BE2;color:white;padding:10px;border:none;border-radius:20px;margin:10px auto;display:block;">Load More</button>',
      );
    }
    content = content.replaceAll(RegExp(r'<a[^>]*data-after[^>]*>.*?</a>', dotAll: true), '');

    if (before == null || before.isEmpty || before == '0') {
      final docFull = html_parser.parse(html);
      final channelName = docFull.querySelector('.tgme_header_title')?.text.trim() ?? chid;
      final subscribers = docFull.querySelector('.tgme_header_counter')?.text.trim() ?? '';
      String avatarPath = '';
      final cacheFile = File('${cacheDir.path}/${chid}_info.json');
      if (await cacheFile.exists()) {
        final cached = jsonDecode(await cacheFile.readAsString());
        avatarPath = cached['avatar'] ?? '';
      }
      final header = '''
        <div style="background:#1A1A1A; padding:15px; display:flex; gap:15px; align-items:center; border-bottom:1px solid #333;">
          <img src="$avatarPath" width="50" height="50" style="border-radius:25px;">
          <div>
            <strong style="font-size:18px;">$channelName</strong>
            <div style="font-size:12px; color:#888;">$subscribers</div>
          </div>
        </div>
      ''';
      content = header + content;
    }
    return content;
  }

  static Map<String, dynamic> _convertGitHubToChannelInfo(String chid, Map<String, dynamic> githubData) {
    final info = githubData['info'] ?? {};
    return {
      'name': info['title'] ?? info['username'] ?? chid,
      'avatar': info['photo_url'],
      'desc': githubData['posts']?.isNotEmpty == true ? githubData['posts'][0]['message']?.substring(0, 100) : 'No description',
      'datestr': githubData['posts']?.isNotEmpty == true ? _toPersianDate(DateTime.tryParse(githubData['posts'][0]['date']) ?? DateTime.now()) : '',
      'newmsg': '',
    };
  }

  static String _convertGitHubToHtml(Map<String, dynamic> githubData) {
    final posts = githubData['posts'] as List?;
    if (posts == null || posts.isEmpty) return '<div>No posts available</div>';
    final buffer = StringBuffer();
    for (var post in posts) {
      final date = DateTime.tryParse(post['date'] ?? '');
      final dateStr = date != null ? _toPersianDate(date) : 'Unknown date';
      buffer.write('''
        <div style="background:#1E1E1E; margin:8px; padding:12px; border-radius:16px;">
          <div style="color:#888; font-size:12px;">$dateStr</div>
          <div style="margin-top:8px;">${post['message'] ?? ''}</div>
        </div>
      ''');
    }
    return buffer.toString();
  }

  static Future<Map<String, dynamic>> _parseChannelInfoFromHtml(String chid, String html) async {
    final document = html_parser.parse(html);
    final result = <String, dynamic>{};
    final title = document.querySelector('meta[property="og:title"]');
    result['name'] = title?.attributes['content'] ?? chid;
    final ogImage = document.querySelector('meta[property="og:image"]');
    if (ogImage != null) {
      final imgUrl = ogImage.attributes['content'];
      if (imgUrl != null && imgUrl.isNotEmpty) {
        final hash = _md5(imgUrl);
        final filename = '$hash.jpg';
        if (await _downloadImage(imgUrl, filename)) result['avatar'] = '${cacheDir.path}/$filename';
      }
    }
    final lastPost = document.querySelector('.tgme_widget_message');
    if (lastPost != null) {
      final textElem = lastPost.querySelector('.tgme_widget_message_text');
      result['desc'] = textElem?.text.trim() ?? '📎 Media';
      final timeElem = lastPost.querySelector('time');
      if (timeElem != null && timeElem.attributes['datetime'] != null) {
        final dt = DateTime.parse(timeElem.attributes['datetime']!);
        result['datestr'] = _toPersianDate(dt);
      }
    }
    return result;
  }

  static Future<bool> _downloadImage(String url, String filename) async {
    final file = File('${cacheDir.path}/$filename');
    if (await file.exists()) return true;
    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        await file.writeAsBytes(response.bodyBytes);
        return true;
      }
    } catch (_) {}
    return false;
  }

  static Future<List<String>> getSavedChannels() async => _prefs.getStringList('channels') ?? [];
  static Future<void> addChannel(String chid) async {
    final list = await getSavedChannels();
    if (!list.contains(chid)) {
      list.add(chid);
      await _prefs.setStringList('channels', list);
    }
  }
  static Future<void> removeChannel(String chid) async {
    final list = await getSavedChannels();
    list.remove(chid);
    await _prefs.setStringList('channels', list);
  }
  static Future<void> updateChannelsOrder(List<String> newOrder) async => await _prefs.setStringList('channels', newOrder);

  static String _md5(String input) => base64Url.encode(utf8.encode(input)).substring(0, 16);
  static String _toPersianDate(DateTime dt) {
    final (jy, jm, jd) = _gregorianToJalali(dt.year, dt.month, dt.day);
    final time = DateFormat.Hm().format(dt);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final inputDate = DateTime(dt.year, dt.month, dt.day);
    if (inputDate == today) return 'Today $time';
    if (inputDate == yesterday) return 'Yesterday $time';
    return '$jy-${jm.toString().padLeft(2, '0')}-${jd.toString().padLeft(2, '0')} $time';
  }
  static (int year, int month, int day) _gregorianToJalali(int gy, int gm, int gd) {
    const gdm = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334];
    var gy2 = gm > 2 ? gy + 1 : gy;
    var days = 355666 + (365 * gy) + ((gy2 + 3) ~/ 4) - ((gy2 + 99) ~/ 100) + ((gy2 + 399) ~/ 400) + gd + gdm[gm - 1];
    var jy = -1595 + (33 * (days ~/ 12053));
    days %= 12053;
    jy += 4 * (days ~/ 1461);
    days %= 1461;
    if (days > 365) {
      jy += (days - 1) ~/ 365;
      days = (days - 1) % 365;
    }
    final jm = days < 186 ? 1 + (days ~/ 31) : 7 + ((days - 186) ~/ 30);
    final jd = 1 + (days < 186 ? days % 31 : (days - 186) % 30);
    return (jy, jm, jd);
  }
}

class ChannelItem {
  final String id;
  String name;
  String? avatarPath;
  String? lastMessage;
  String? lastDate;
  int unreadCount;
  ChannelItem({required this.id, required this.name, this.avatarPath, this.lastMessage, this.lastDate, this.unreadCount = 0});
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<ChannelItem> _channels = [];
  ChannelItem? _selectedChannel;
  String _messagesHtml = '';
  bool _isLoading = true;
  bool _isLoadingMessages = false;
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _loadChannels();
  }

  Future<void> _loadChannels() async {
    final savedIds = await TelegramService.getSavedChannels();
    final List<ChannelItem> temp = [];
    for (final id in savedIds) {
      try {
        final info = await TelegramService.fetchChannelInfo(id);
        temp.add(ChannelItem(
          id: id,
          name: info['name'] ?? id,
          avatarPath: info['avatar'],
          lastMessage: info['desc'],
          lastDate: info['datestr'],
          unreadCount: 0,
        ));
        setState(() {});
        await Future.delayed(const Duration(milliseconds: 200));
      } catch (e) {
        temp.add(ChannelItem(id: id, name: id, lastMessage: 'Error loading'));
      }
    }
    setState(() {
      _channels = temp;
      _isLoading = false;
    });
    if (_channels.isNotEmpty) await _selectChannel(_channels.first);
  }

  Future<void> _addChannel(String rawId) async {
    final cleanId = rawId.trim().replaceAll('@', '').replaceAll('https://t.me/', '').replaceAll('t.me/', '').replaceAll('/s/', '');
    if (cleanId.isEmpty) return;
    if (_channels.any((c) => c.id == cleanId)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Channel already added')));
      return;
    }
    setState(() => _isLoading = true);
    await TelegramService.addChannel(cleanId);
    await _loadChannels();
  }

  Future<void> _removeChannel(String id) async {
    await TelegramService.removeChannel(id);
    if (_selectedChannel?.id == id) setState(() => _selectedChannel = null);
    await _loadChannels();
  }

  Future<void> _selectChannel(ChannelItem channel) async {
    if (_selectedChannel?.id == channel.id) return;
    setState(() {
      _selectedChannel = channel;
      _messagesHtml = '';
      _isLoadingMessages = true;
    });
    try {
      final html = await TelegramService.fetchMessagesHtml(channel.id);
      setState(() {
        _messagesHtml = html;
        _isLoadingMessages = false;
      });
    } catch (e) {
      setState(() => _isLoadingMessages = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  void _showSearchDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Channel', style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.grey[900],
        content: TextField(
          controller: _searchController,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(hintText: '@username or t.me/...', hintStyle: TextStyle(color: Colors.grey), border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel', style: TextStyle(color: Colors.grey))),
          ElevatedButton(
            onPressed: () {
              _addChannel(_searchController.text);
              Navigator.pop(context);
              _searchController.clear();
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.purple),
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  Future<void> _reorderChannels(int oldIndex, int newIndex) async {
    if (oldIndex == newIndex) return;
    setState(() {
      final item = _channels.removeAt(oldIndex);
      _channels.insert(newIndex, item);
    });
    final newOrderIds = _channels.map((c) => c.id).toList();
    await TelegramService.updateChannelsOrder(newOrderIds);
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _channels.where((c) => c.name.toLowerCase().contains(_searchQuery.toLowerCase()) || c.id.toLowerCase().contains(_searchQuery.toLowerCase())).toList();
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text('EzyTel Pro'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [IconButton(icon: const Icon(Icons.search), onPressed: _showSearchDialog)],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Colors.black, Colors.grey[900]!],
          ),
        ),
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : Row(
                children: [
                  Container(
                    width: 300,
                    color: Colors.black.withOpacity(0.3),
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: TextField(
                            onChanged: (v) => setState(() => _searchQuery = v),
                            decoration: const InputDecoration(
                              hintText: 'Filter channels...',
                              prefixIcon: Icon(Icons.filter_list),
                              filled: true,
                              fillColor: Colors.transparent,
                              border: OutlineInputBorder(borderSide: BorderSide.none, borderRadius: BorderRadius.all(Radius.circular(30))),
                            ),
                          ),
                        ),
                        Expanded(
                          child: ReorderableListView.builder(
                            onReorder: _reorderChannels,
                            itemCount: filtered.length,
                            itemBuilder: (ctx, i) {
                              final ch = filtered[i];
                              return Dismissible(
                                key: Key(ch.id),
                                direction: DismissDirection.endToStart,
                                background: Container(color: Colors.red, alignment: Alignment.centerRight, padding: const EdgeInsets.only(right: 20), child: const Icon(Icons.delete, color: Colors.white)),
                                onDismissed: (_) => _removeChannel(ch.id),
                                child: ListTile(
                                  key: Key(ch.id),
                                  leading: ClipOval(
                                    child: ch.avatarPath != null && File(ch.avatarPath!).existsSync()
                                        ? Image.file(File(ch.avatarPath!), width: 48, height: 48, fit: BoxFit.cover)
                                        : Container(width: 48, height: 48, color: Colors.purple, child: Center(child: Text(ch.name[0].toUpperCase(), style: const TextStyle(fontSize: 20)))),
                                  ),
                                  title: Text(ch.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                                  subtitle: Text(ch.lastMessage ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                                  trailing: ch.unreadCount > 0
                                      ? Container(width: 28, height: 28, decoration: const BoxDecoration(color: Colors.purple, shape: BoxShape.circle), child: Center(child: Text('${ch.unreadCount}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold))))
                                      : null,
                                  selected: _selectedChannel?.id == ch.id,
                                  selectedTileColor: Colors.purpleAccent,
                                  onTap: () => _selectChannel(ch),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: _selectedChannel == null
                        ? const Center(child: Text('Select a channel', style: TextStyle(color: Colors.grey)))
                        : _isLoadingMessages
                            ? const Center(child: CircularProgressIndicator())
                            : SingleChildScrollView(
                                controller: _scrollController,
                                reverse: true,
                                padding: const EdgeInsets.all(12),
                                child: HtmlWidget(html: _messagesHtml),
                              ),
                  ),
                ],
              ),
      ),
      floatingActionButton: FloatingActionButton(onPressed: _showSearchDialog, backgroundColor: Colors.purple, child: const Icon(Icons.add)),
    );
  }
}

class HtmlWidget extends StatelessWidget {
  final String html;
  const HtmlWidget({super.key, required this.html});
  @override
  Widget build(BuildContext context) {
    final clean = html.replaceAll(RegExp(r'<[^>]*>'), ' ').trim();
    return Text(clean, style: const TextStyle(color: Colors.white, height: 1.5));
  }
}
