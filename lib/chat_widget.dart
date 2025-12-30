import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'package:intl/intl.dart'; 
import 'secrets.dart'; 

class ChatWidget extends StatefulWidget {
  final String loanId;
  final String currentSender; // 'user' or 'admin'
  final bool isReadOnly;
  final VoidCallback? onRefreshDetails; 

  const ChatWidget({
    super.key,
    required this.loanId,
    required this.currentSender,
    this.isReadOnly = false,
    this.onRefreshDetails,
  });

  @override
  State<ChatWidget> createState() => _ChatWidgetState();
}

class _ChatWidgetState extends State<ChatWidget> {
  final TextEditingController _msgController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode(); 

  List<Map<String, dynamic>> _messages = [];
  bool _isSending = false;
  
  // Streaming connection
  http.Client? _client;
  StreamSubscription? _streamSubscription;

  @override
  void initState() {
    super.initState();
    _startStreaming();
  }

  @override
  void dispose() {
    _stopStreaming();
    _msgController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // --- 1. STREAMING LOGIC (Server-Sent Events) ---
  void _startStreaming() {
    _client = http.Client();
    String cleanId = widget.loanId.contains('/') ? widget.loanId.split('/').last : widget.loanId;
    
    // Use rtdbUrl from secrets.dart
    final url = Uri.parse('${rtdbUrl}chats/$cleanId.json');
    
    final request = http.Request('GET', url);
    request.headers['Accept'] = 'text/event-stream';

    _client!.send(request).then((response) {
      _streamSubscription = response.stream
        .transform(utf8.decoder) 
        .transform(const LineSplitter()) 
        .listen((line) {
          if (line.contains('put') || line.contains('patch')) {
             _fetchFullList();
          }
          if (line.startsWith('data: ') && !line.contains('null')) {
             _fetchFullList();
          }
        }, onError: (e) {
          // print("Stream error: $e");
        });
    });
  }

  void _stopStreaming() {
    _streamSubscription?.cancel();
    _client?.close();
  }

  Future<void> _fetchFullList() async {
    if (!mounted) return;
    String cleanId = widget.loanId.contains('/') ? widget.loanId.split('/').last : widget.loanId;
    final url = Uri.parse('${rtdbUrl}chats/$cleanId.json');

    try {
      final response = await http.get(url);
      if (response.statusCode == 200 && response.body != "null") {
        final Map<String, dynamic> data = jsonDecode(response.body);
        List<Map<String, dynamic>> loadedMsgs = [];
        
        data.forEach((key, value) {
          loadedMsgs.add({
            'id': key, // This Key is the Firebase Push ID (chronological)
            'text': value['text'] ?? "",
            'sender': value['sender'] ?? "unknown",
            'timestamp': value['timestamp'] ?? "",
          });
        });

        // --- THE FIX IS HERE ---
        // Old: Sort by timestamp (Depends on user clock, unreliable)
        // New: Sort by ID (Depends on Server Order, 100% reliable)
        loadedMsgs.sort((a, b) => a['id'].compareTo(b['id']));
        // -----------------------
        
        if (mounted) {
          setState(() => _messages = loadedMsgs);
          if (_scrollController.hasClients) {
             Future.delayed(const Duration(milliseconds: 100), () {
               _scrollController.animateTo(
                 _scrollController.position.maxScrollExtent,
                 duration: const Duration(milliseconds: 300),
                 curve: Curves.easeOut,
               );
             });
          }
        }
      } else {
         if (mounted) setState(() => _messages = []);
      }
    } catch (e) {}
  }

  Future<void> _sendMessage(String text) async {
    if (text.trim().isEmpty) return;
    _msgController.clear();
    setState(() => _isSending = true);

    String cleanId = widget.loanId.contains('/') ? widget.loanId.split('/').last : widget.loanId;
    final url = Uri.parse('${rtdbUrl}chats/$cleanId.json');

    try {
      await http.post(url, body: jsonEncode({
        "text": text,
        "sender": widget.currentSender,
        "timestamp": DateTime.now().toUtc().toIso8601String(),
      }));
      _focusNode.requestFocus(); 
    } catch (e) {
      print("Send Error: $e");
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  Future<void> _updateProposalStatus(String msgId, String key, String value, String label, String newStatus) async {
    String cleanId = widget.loanId.contains('/') ? widget.loanId.split('/').last : widget.loanId;
    final url = Uri.parse('${rtdbUrl}chats/$cleanId/$msgId.json');
    String newMsg = "PROP::$key::$value::$label::$newStatus";
    try {
      await http.patch(url, body: jsonEncode({"text": newMsg}));
    } catch (e) { print(e); }
  }

  Future<void> _handleAccept(String key, String value, String label, String msgId) async {
    String cleanId = widget.loanId.contains('/') ? widget.loanId.split('/').last : widget.loanId;
    
    final updateUrl = Uri.parse('https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents/loan_applications/$cleanId?updateMask.fieldPaths=$key');
    
    Map<String, dynamic> valMap;
    if (key == 'loan_amount' || key == 'salary' || key == 'months') {
       valMap = {"integerValue": value};
    } else {
       valMap = {"stringValue": value};
    }

    try {
      await http.patch(updateUrl, body: jsonEncode({"fields": {key: valMap}}));
      await _updateProposalStatus(msgId, key, value, label, "ACCEPTED");
      if (widget.onRefreshDetails != null) widget.onRefreshDetails!(); 
    } catch (e) { print(e); }
  }

  Future<void> _handleReject(String key, String value, String label, String msgId) async {
    await _updateProposalStatus(msgId, key, value, label, "REJECTED");
  }

  Future<void> _handleCancel(String key, String value, String label, String msgId) async {
    await _updateProposalStatus(msgId, key, value, label, "CANCELED");
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isReadOnly) {
      return const Center(child: Text("Chat closed.", style: TextStyle(color: Colors.grey)));
    }

    bool isAdmin = widget.currentSender == 'admin';
    String hintText = isAdmin ? "Message User..." : "Message Admin...";

    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.all(16),
            itemCount: _messages.length,
            itemBuilder: (context, index) {
              final msg = _messages[index];
              final text = msg['text'];
              final sender = msg['sender'];
              final isMe = sender == widget.currentSender;

              if (text.startsWith("PROP::")) {
                return _buildProposalCard(text, sender, isMe, msg['id']);
              }

              return Align(
                alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: isMe ? Colors.blue : Colors.grey[300],
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    text, 
                    style: TextStyle(
                      color: isMe ? Colors.white : Colors.black87
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        Container(
          padding: const EdgeInsets.all(8),
          color: Colors.white,
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _msgController, 
                focusNode: _focusNode, 
                textInputAction: TextInputAction.send,
                onSubmitted: (val) => _sendMessage(val),
                decoration: InputDecoration(
                    hintText: hintText, 
                    border: InputBorder.none, 
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10)
                )
              )
            ),
            IconButton(icon: const Icon(Icons.send, color: Colors.blue), onPressed: () => _sendMessage(_msgController.text)),
          ]),
        ),
      ],
    );
  }

  Widget _buildProposalCard(String rawText, String sender, bool isMe, String msgId) {
    final parts = rawText.split("::");
    if (parts.length < 4) return const SizedBox.shrink();

    String key = parts[1];
    String rawValue = parts[2];
    String label = parts[3];
    String status = parts.length > 4 ? parts[4] : "PENDING"; 

    String displayValue = rawValue;
    final currencyFmt = NumberFormat("#,##0");
    if (key == 'loan_amount' || key == 'salary') {
       displayValue = "${currencyFmt.format(double.tryParse(rawValue) ?? 0)} Baht";
    } else if (key == 'months') {
       displayValue = "$rawValue Months";
    }

    String senderName = sender == 'admin' ? "Admin" : "User";
    
    Color bgColor = Colors.orange[50]!;
    Color borderColor = Colors.orange;
    if (status == 'ACCEPTED') { bgColor = Colors.green[50]!; borderColor = Colors.green; }
    else if (status == 'REJECTED') { bgColor = Colors.red[50]!; borderColor = Colors.red; }
    else if (status == 'CANCELED') { bgColor = Colors.grey[200]!; borderColor = Colors.grey; }

    return Align(
      alignment: Alignment.center,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.all(12),
        width: 280,
        decoration: BoxDecoration(color: bgColor, border: Border.all(color: borderColor), borderRadius: BorderRadius.circular(12)),
        child: Column(
          children: [
            if (status == 'PENDING') ...[
              const Icon(Icons.edit_note, color: Colors.orange),
              const SizedBox(height: 4),
              Text(isMe ? "You proposed changing\n$label to:" : "$senderName proposes changing\n$label to:", textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, color: Colors.grey)),
              Text(displayValue, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black87)),
              const SizedBox(height: 12),
              
              if (!isMe) 
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ElevatedButton(
                      onPressed: () => _handleReject(key, rawValue, label, msgId),
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
                      child: const Text("Reject"),
                    ),
                    ElevatedButton(
                      onPressed: () => _handleAccept(key, rawValue, label, msgId), 
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
                      child: const Text("Accept"),
                    ),
                  ],
                )
              else
                TextButton.icon(
                  onPressed: () => _handleCancel(key, rawValue, label, msgId),
                  icon: const Icon(Icons.cancel, size: 16, color: Colors.grey),
                  label: const Text("Cancel Proposal", style: TextStyle(color: Colors.grey)),
                )

            ] else if (status == 'ACCEPTED') ...[
              const Icon(Icons.check_circle, color: Colors.green),
              const SizedBox(height: 4),
              Text("Proposal Accepted", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.green[800])),
              Text("Changed $label to $displayValue", style: const TextStyle(fontSize: 13, color: Colors.black54)),

            ] else if (status == 'REJECTED') ...[
              const Icon(Icons.cancel, color: Colors.red),
              const SizedBox(height: 4),
              Text("Proposal Rejected", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red[800])),
              Text("Proposed: $displayValue", style: const TextStyle(fontSize: 13, color: Colors.black54, decoration: TextDecoration.lineThrough)),

            ] else if (status == 'CANCELED') ...[
              const Icon(Icons.remove_circle_outline, color: Colors.grey),
              const SizedBox(height: 4),
              const Text("Proposal Canceled", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black54)),
              Text("Was: $displayValue", style: const TextStyle(fontSize: 13, color: Colors.grey)),
            ]
          ],
        ),
      ),
    );
  }
}