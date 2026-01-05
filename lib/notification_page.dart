import 'package:flutter/material.dart';
import 'loan_details_page.dart';

class NotificationPage extends StatefulWidget {
  final int unreadCount;
  final VoidCallback onClear;
  final Map<String, dynamic>? loanData;
  final String? loanId;
  final VoidCallback? onRefresh;

  const NotificationPage({
    super.key,
    required this.unreadCount,
    required this.onClear,
    this.loanData,
    this.loanId,
    this.onRefresh,
  });

  @override
  State<NotificationPage> createState() => _NotificationPageState();
}

class _NotificationPageState extends State<NotificationPage> {
  // Local state to hide items immediately when "Mark all as read" is clicked
  late int _displayCount;

  @override
  void initState() {
    super.initState();
    _displayCount = widget.unreadCount;
  }

  void _handleClear() {
    setState(() {
      _displayCount = 0;
    });
    widget.onClear(); // Tell the parent (Homepage) to reset the counter too
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Notifications", style: TextStyle(color: Colors.black)),
        backgroundColor: Colors.white,
        elevation: 0,
        leading: const BackButton(color: Colors.black),
        actions: [
          if (_displayCount > 0)
            IconButton(
              icon: const Icon(Icons.done_all, color: Colors.blue),
              onPressed: _handleClear,
              tooltip: "Mark all as read",
            )
        ],
      ),
      body: _displayCount == 0
          ? const Center(
              child: Text("No new notifications.",
                  style: TextStyle(color: Colors.grey)))
          : ListView.builder(
              itemCount: _displayCount,
              itemBuilder: (c, i) => ListTile(
                leading: const CircleAvatar(
                    backgroundColor: Colors.blue,
                    child: Icon(Icons.chat, color: Colors.white, size: 16)),
                title: const Text("New Admin Message or Status Update"),
                subtitle: const Text("Tap to view details."),
                onTap: () async {
                  if (widget.loanId != null && widget.loanData != null) {
                    // Navigate to details
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => LoanDetailsPage(
                          loanData: widget.loanData!,
                          loanId: widget.loanId!,
                          onUpdate: widget.onRefresh ?? () {},
                          currentUserType: 'user',
                        ),
                      ),
                    );
                    
                    // After returning:
                    if (widget.onRefresh != null) widget.onRefresh!();
                    
                    // Mark as read automatically since they viewed it
                    _handleClear();
                    
                    if (context.mounted) {
                      Navigator.pop(context); // Close notification page
                    }
                  } else {
                    Navigator.pop(context);
                  }
                },
              ),
            ),
    );
  }
}