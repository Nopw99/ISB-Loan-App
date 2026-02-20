import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';

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

  bool _isSending = false;

  // Helper to get the clean document ID
  String get cleanId => widget.loanId.contains('/') ? widget.loanId.split('/').last : widget.loanId;

  @override
  void dispose() {
    _msgController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // --- 1. SEND MESSAGE ---
  Future<void> _sendMessage(String text) async {
    if (text.trim().isEmpty) return;
    _msgController.clear();
    setState(() => _isSending = true);

    try {
      await FirebaseFirestore.instance
          .collection('loan_applications')
          .doc(cleanId)
          .collection('messages')
          .add({
        "text": text,
        "sender": widget.currentSender,
        // Using native server timestamp
        "timestamp": FieldValue.serverTimestamp(), 
      });
      _focusNode.requestFocus();
    } catch (e) {
      debugPrint("Send Error: $e");
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  // --- 2. PROPOSAL LOGIC ---
  Future<void> _updateProposalStatus(String msgId, String key, String value, String label, String newStatus) async {
    String newMsg = "PROP::$key::$value::$label::$newStatus";
    try {
      await FirebaseFirestore.instance
          .collection('loan_applications')
          .doc(cleanId)
          .collection('messages')
          .doc(msgId)
          .update({"text": newMsg});
    } catch (e) {
      debugPrint("Update Proposal Error: $e");
    }
  }

  Future<void> _handleAccept(String key, String value, String label, String msgId) async {
    dynamic finalValue;

    // Convert string back to native Dart types based on the key
    if (key == 'loan_amount' || key == 'salary' || key == 'months') {
      String cleanVal = value.replaceAll(',', '').split('.')[0];
      finalValue = int.tryParse(cleanVal) ?? 0;
    } else if (key == 'interest_rate') {
      finalValue = double.tryParse(value) ?? 0.0;
    } else {
      finalValue = value;
    }

    try {
      // Update the main loan document
      await FirebaseFirestore.instance
          .collection('loan_applications')
          .doc(cleanId)
          .update({key: finalValue});
      
      // Update the chat message status
      await _updateProposalStatus(msgId, key, value, label, "ACCEPTED");
      
      if (widget.onRefreshDetails != null) widget.onRefreshDetails!();
    } catch (e) {
      debugPrint("Accept Error: $e");
    }
  }

  Future<void> _handleReject(String key, String value, String label, String msgId) async {
    await _updateProposalStatus(msgId, key, value, label, "REJECTED");
  }

  Future<void> _handleCancel(String key, String value, String label, String msgId) async {
    await _updateProposalStatus(msgId, key, value, label, "CANCELED");
  }

  // --- 3. UI BUILDER ---
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
          // Use StreamBuilder for automatic live updates!
          child: StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('loan_applications')
                .doc(cleanId)
                .collection('messages')
                .orderBy('timestamp') // Sorts chronologically
                .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Center(child: Text("Error loading chat: ${snapshot.error}"));
              }
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }

              final docs = snapshot.data!.docs;

              // Auto-scroll trick: delay slightly to let ListView build
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (_scrollController.hasClients) {
                  _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
                }
              });

              return ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.all(16),
                itemCount: docs.length,
                itemBuilder: (context, index) {
                  final msgData = docs[index].data() as Map<String, dynamic>;
                  final msgId = docs[index].id;
                  final text = msgData['text'] ?? '';
                  final sender = msgData['sender'] ?? 'unknown';
                  final isMe = sender == widget.currentSender;

                  if (text.startsWith("PROP::")) {
                    return _buildProposalCard(text, sender, isMe, msgId);
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
                            color: isMe ? Colors.white : Colors.black87),
                      ),
                    ),
                  );
                },
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
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10)),
              ),
            ),
            IconButton(
              icon: _isSending 
                  ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)) 
                  : const Icon(Icons.send, color: Colors.blue),
              onPressed: _isSending ? null : () => _sendMessage(_msgController.text),
            ),
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

    if (key == 'loan_amount') {
      double total = double.tryParse(rawValue) ?? 0;
      double principal = ((total / 1.05) + 0.01).floorToDouble();
      displayValue = "${currencyFmt.format(principal)} Baht";
    } else if (key == 'salary') {
      displayValue = "${currencyFmt.format(double.tryParse(rawValue) ?? 0)} Baht";
    } else if (key == 'months') {
      displayValue = "$rawValue Months";
    }

    String senderName = sender == 'admin' ? "Admin" : "User";

    Color bgColor = Colors.orange[50]!;
    Color borderColor = Colors.orange;
    if (status == 'ACCEPTED') {
      bgColor = Colors.green[50]!;
      borderColor = Colors.green;
    } else if (status == 'REJECTED') {
      bgColor = Colors.red[50]!;
      borderColor = Colors.red;
    } else if (status == 'CANCELED') {
      bgColor = Colors.grey[200]!;
      borderColor = Colors.grey;
    }

    return Align(
      alignment: Alignment.center,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.all(12),
        width: 280,
        decoration: BoxDecoration(
            color: bgColor,
            border: Border.all(color: borderColor),
            borderRadius: BorderRadius.circular(12)),
        child: Column(
          children: [
            if (status == 'PENDING') ...[
              const Icon(Icons.edit_note, color: Colors.orange),
              const SizedBox(height: 4),
              Text(
                  isMe
                      ? "You proposed changing\n$label to:"
                      : "$senderName proposes changing\n$label to:",
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
              Text(displayValue,
                  style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.black87)),
              const SizedBox(height: 12),
              if (!isMe)
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ElevatedButton(
                      onPressed: () => _handleReject(key, rawValue, label, msgId),
                      style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                          foregroundColor: Colors.white),
                      child: const Text("Reject"),
                    ),
                    ElevatedButton(
                      onPressed: () => _handleAccept(key, rawValue, label, msgId),
                      style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white),
                      child: const Text("Accept"),
                    ),
                  ],
                )
              else
                TextButton.icon(
                  onPressed: () => _handleCancel(key, rawValue, label, msgId),
                  icon: const Icon(Icons.cancel, size: 16, color: Colors.grey),
                  label: const Text("Cancel Proposal",
                      style: TextStyle(color: Colors.grey)),
                )
            ] else if (status == 'ACCEPTED') ...[
              const Icon(Icons.check_circle, color: Colors.green),
              const SizedBox(height: 4),
              Text("Proposal Accepted",
                  style: TextStyle(
                      fontWeight: FontWeight.bold, color: Colors.green[800])),
              Text("Changed $label to $displayValue",
                  style: const TextStyle(fontSize: 13, color: Colors.black54)),
            ] else if (status == 'REJECTED') ...[
              const Icon(Icons.cancel, color: Colors.red),
              const SizedBox(height: 4),
              Text("Proposal Rejected",
                  style: TextStyle(
                      fontWeight: FontWeight.bold, color: Colors.red[800])),
              Text("Proposed: $displayValue",
                  style: const TextStyle(
                      fontSize: 13,
                      color: Colors.black54,
                      decoration: TextDecoration.lineThrough)),
            ] else if (status == 'CANCELED') ...[
              const Icon(Icons.remove_circle_outline, color: Colors.grey),
              const SizedBox(height: 4),
              Text("Proposal Canceled",
                  style: TextStyle(
                      fontWeight: FontWeight.bold, color: Colors.black54)),
              Text("Was: $displayValue",
                  style: const TextStyle(fontSize: 13, color: Colors.grey)),
            ]
          ],
        ),
      ),
    );
  }
}