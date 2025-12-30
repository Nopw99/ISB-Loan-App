import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:intl/intl.dart';
import 'main.dart'; // For Gradient
import 'loan_details_page.dart';
import 'secrets.dart';

// 1. Define Sort Options
enum HistorySortOption {
  dateNewest,
  dateOldest,
  amountHigh,
  amountLow,
}

class LoanHistoryPage extends StatefulWidget {
  final String userEmail;

  const LoanHistoryPage({super.key, required this.userEmail});

  @override
  State<LoanHistoryPage> createState() => _LoanHistoryPageState();
}

class _LoanHistoryPageState extends State<LoanHistoryPage> {
  List<dynamic> _myLoans = [];
  bool _isLoading = true;
  final _formatter = NumberFormat("#,##0");
  
  // Default Sort: Newest First
  HistorySortOption _currentSort = HistorySortOption.dateNewest;

  @override
  void initState() {
    super.initState();
    _fetchHistory();
  }

  Future<void> _fetchHistory() async {
    final url = Uri.parse(
        'https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents/loan_applications');

    try {
      final response = await http.get(url);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final allDocs = data['documents'] ?? [];

        List<dynamic> filtered = [];
        for (var doc in allDocs) {
          final fields = doc['fields'];
          if (fields == null) continue;
          
          String? email = fields['email']?['stringValue'];
          if (email != null && email.trim().toLowerCase() == widget.userEmail.trim().toLowerCase()) {
            filtered.add(doc);
          }
        }

        if (mounted) {
          setState(() {
            _myLoans = filtered;
            _sortHistory(); // Sort immediately after fetching
            _isLoading = false;
          });
        }
      }
    } catch (e) {
      print(e);
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // 2. SORTING LOGIC
  void _sortHistory() {
    _myLoans.sort((a, b) {
      final fieldsA = a['fields'];
      final fieldsB = b['fields'];

      int getAmount(dynamic f) => int.tryParse(f['loan_amount']?['integerValue'] ?? '0') ?? 0;
      DateTime getDate(dynamic f) {
        String? ts = f['timestamp']?['timestampValue'];
        return ts != null ? DateTime.parse(ts) : DateTime(1970);
      }

      switch (_currentSort) {
        case HistorySortOption.dateNewest:
          return getDate(fieldsB).compareTo(getDate(fieldsA)); // Newest first
        case HistorySortOption.dateOldest:
          return getDate(fieldsA).compareTo(getDate(fieldsB)); // Oldest first
        case HistorySortOption.amountHigh:
          return getAmount(fieldsB).compareTo(getAmount(fieldsA)); // Most loan first
        case HistorySortOption.amountLow:
          return getAmount(fieldsA).compareTo(getAmount(fieldsB)); // Least loan first
      }
    });
  }

  void _onSortSelected(HistorySortOption option) {
    setState(() {
      _currentSort = option;
      _sortHistory();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text("Application History", style: TextStyle(color: Colors.black)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.black),
        actions: [
          // 3. SORT BUTTON UI
          PopupMenuButton<HistorySortOption>(
            icon: const Icon(Icons.sort, color: Colors.black),
            tooltip: "Sort History",
            onSelected: _onSortSelected,
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: HistorySortOption.dateNewest,
                child: Text("Newest First"),
              ),
              const PopupMenuItem(
                value: HistorySortOption.dateOldest,
                child: Text("Oldest First"),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: HistorySortOption.amountHigh,
                child: Text("Loan Amount (Highest)"),
              ),
              const PopupMenuItem(
                value: HistorySortOption.amountLow,
                child: Text("Loan Amount (Lowest)"),
              ),
            ],
          ),
        ],
      ),
      body: Container(
        decoration: kAppBackground,
        child: _isLoading 
          ? const Center(child: CircularProgressIndicator())
          : _myLoans.isEmpty 
            ? const Center(child: Text("No history found.", style: TextStyle(color: Colors.grey)))
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 100, 16, 24),
                itemCount: _myLoans.length,
                itemBuilder: (context, index) {
                  final loan = _myLoans[index];
                  final fields = loan['fields'];
                  final nameId = loan['name'];

                  String status = fields['status']?['stringValue'] ?? 'pending';
                  String amount = fields['loan_amount']?['integerValue'] ?? '0';
                  
                  // Check if archived
                  bool isHidden = fields['is_hidden']?['booleanValue'] ?? false;
                  
                  return Card(
                    margin: const EdgeInsets.only(bottom: 12),
                    elevation: 3,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      title: Text("${_formatter.format(int.parse(amount))} THB", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                      subtitle: Row(
                        children: [
                          Text("Status: ${status.toUpperCase()}"),
                          if (isHidden) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(color: Colors.grey[200], borderRadius: BorderRadius.circular(4)),
                              child: const Text("ARCHIVED", style: TextStyle(fontSize: 10, color: Colors.grey)),
                            )
                          ]
                        ],
                      ),
                      trailing: const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.grey),
                      leading: CircleAvatar(
                        backgroundColor: _getStatusColor(status).withOpacity(0.1),
                        child: Icon(_getStatusIcon(status), color: _getStatusColor(status)),
                      ),
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => LoanDetailsPage(
                              loanData: fields,
                              loanId: nameId,
                              onUpdate: _fetchHistory, 
                              currentUserType: 'user',
                            ),
                          ),
                        );
                      },
                    ),
                  );
                },
              ),
      ),
    );
  }

  Color _getStatusColor(String status) {
    switch (status.toLowerCase()) {
      case 'approved': return Colors.green;
      case 'rejected': return Colors.red;
      default: return Colors.orange;
    }
  }

  IconData _getStatusIcon(String status) {
    switch (status.toLowerCase()) {
      case 'approved': return Icons.check;
      case 'rejected': return Icons.close;
      default: return Icons.hourglass_empty;
    }
  }
}