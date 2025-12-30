import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'loan_details_page.dart'; // <--- UPDATED IMPORT
import 'main.dart'; 
import 'secrets.dart';

// Define Sort Options
enum SortOption {
  dateNewest,
  dateOldest,
  amountHigh,
  amountLow,
  salaryHigh,
  salaryLow,
}

class AdminHomepage extends StatefulWidget {
  final String adminName;
  final VoidCallback onLogoutTap;

  const AdminHomepage({
    super.key, 
    required this.adminName, 
    required this.onLogoutTap
  });

  @override
  State<AdminHomepage> createState() => _AdminHomepageState();
}

class _AdminHomepageState extends State<AdminHomepage> {
  List<dynamic> _applications = [];
  bool _isLoading = true;
  String? _errorMessage;
  
  // Default Sort
  SortOption _currentSort = SortOption.dateNewest;

  @override
  void initState() {
    super.initState();
    _fetchAllApplications();
  }

  Future<void> _fetchAllApplications() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    
    final url = Uri.parse(
        'https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents/loan_applications');

    try {
      final response = await http.get(url);
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        List<dynamic> docs = data['documents'] ?? [];
        
        // Save raw data
        _applications = docs;
        
        // Apply Sort immediately
        _sortApplications();
        
        setState(() {
          _isLoading = false;
        });
      } else {
        throw "Error ${response.statusCode}: ${response.body}";
      }
    } catch (e) {
      print("Admin Error: $e");
      setState(() {
        _isLoading = false;
        _errorMessage = e.toString();
      });
    }
  }

  // --- SORTING LOGIC ---
  void _sortApplications() {
    _applications.sort((a, b) {
      final fieldsA = a['fields'];
      final fieldsB = b['fields'];

      // Helpers to get values safely
      int getAmount(dynamic f) => int.tryParse(f['loan_amount']?['integerValue'] ?? '0') ?? 0;
      int getSalary(dynamic f) => int.tryParse(f['salary']?['integerValue'] ?? '0') ?? 0;
      DateTime getDate(dynamic f) {
        String? ts = f['timestamp']?['timestampValue'];
        return ts != null ? DateTime.parse(ts) : DateTime(1970);
      }

      switch (_currentSort) {
        case SortOption.dateNewest:
          return getDate(fieldsB).compareTo(getDate(fieldsA)); // Descending
        case SortOption.dateOldest:
          return getDate(fieldsA).compareTo(getDate(fieldsB)); // Ascending
          
        case SortOption.amountHigh:
          return getAmount(fieldsB).compareTo(getAmount(fieldsA)); // Descending
        case SortOption.amountLow:
          return getAmount(fieldsA).compareTo(getAmount(fieldsB)); // Ascending
          
        case SortOption.salaryHigh:
          return getSalary(fieldsB).compareTo(getSalary(fieldsA)); // Descending
        case SortOption.salaryLow:
          return getSalary(fieldsA).compareTo(getSalary(fieldsB)); // Ascending
      }
    });
  }

  // Handle Sort Selection
  void _onSortSelected(SortOption option) {
    setState(() {
      _currentSort = option;
      _sortApplications(); 
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text("Admin Dashboard", style: TextStyle(color: Colors.black87, fontWeight: FontWeight.bold)),
        actions: [
          // REFRESH BUTTON
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.black87),
            onPressed: _fetchAllApplications,
            tooltip: "Refresh Data",
          ),

          // SORT BUTTON
          PopupMenuButton<SortOption>(
            icon: const Icon(Icons.sort, color: Colors.black87),
            tooltip: "Sort Applications",
            onSelected: _onSortSelected,
            itemBuilder: (context) => [
              const PopupMenuItem(value: SortOption.dateNewest, child: Text("Date (Newest First)")),
              const PopupMenuItem(value: SortOption.dateOldest, child: Text("Date (Oldest First)")),
              const PopupMenuDivider(),
              const PopupMenuItem(value: SortOption.amountHigh, child: Text("Loan Amount (Highest)")),
              const PopupMenuItem(value: SortOption.amountLow, child: Text("Loan Amount (Lowest)")),
              const PopupMenuDivider(),
              const PopupMenuItem(value: SortOption.salaryHigh, child: Text("Monthly Salary (Highest)")),
              const PopupMenuItem(value: SortOption.salaryLow, child: Text("Monthly Salary (Lowest)")),
            ],
          ),
          
          IconButton(
            icon: const Icon(Icons.logout, color: Colors.red),
            onPressed: widget.onLogoutTap,
            tooltip: "Logout",
          )
        ],
      ),
      body: Container(
        decoration: kAppBackground, 
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null) {
      return Center(child: Text("Error: $_errorMessage", style: const TextStyle(color: Colors.red)));
    }

    if (_applications.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.inbox, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            const Text("No Loan Applications Found", style: TextStyle(fontSize: 18, color: Colors.grey)),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: _fetchAllApplications, child: const Text("Refresh"))
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _fetchAllApplications,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 100, 16, 16), // Top padding for AppBar
        itemCount: _applications.length,
        itemBuilder: (context, index) {
          final app = _applications[index];
          final fields = app['fields'];
          final name = app['name']; 
          
          String email = fields['email']?['stringValue'] ?? "Unknown";
          String status = fields['status']?['stringValue'] ?? "pending";
          String amount = fields['loan_amount']?['integerValue'] ?? "0";
          
          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              leading: CircleAvatar(
                backgroundColor: _getStatusColor(status).withOpacity(0.1),
                child: Icon(_getStatusIcon(status), color: _getStatusColor(status)),
              ),
              title: Text(email, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text("Request: $amount THB"),
              trailing: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: _getStatusColor(status),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  status.toUpperCase(), 
                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)
                ),
              ),
              onTap: () async {
                // Extract Loan ID from the full path
                String loanId = name.split('/').last;

                // Navigate to the Chat-Enabled Details Page
                await Navigator.push(
                  context, 
                  MaterialPageRoute(
                    builder: (context) => LoanDetailsPage(
                      loanData: fields, 
                      loanId: loanId,
                      onUpdate: _fetchAllApplications, // Callback to refresh list
                      currentUserType: 'admin', // <--- IMPORTANT: Enables Admin Chat
                    )
                  )
                );
                _fetchAllApplications(); 
              },
            ),
          );
        },
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