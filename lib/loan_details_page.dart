import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'api_helper.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_saver/file_saver.dart';
import 'main.dart';
import 'chat_widget.dart';
import 'package:flutter/services.dart';
import 'secrets.dart';

class LoanDetailsPage extends StatefulWidget {
  final Map<String, dynamic> loanData;
  final String loanId;
  final VoidCallback onUpdate;
  final String currentUserType;
  final bool isAdmin;

  const LoanDetailsPage({
    super.key,
    required this.loanData,
    required this.loanId,
    required this.onUpdate,
    required this.currentUserType,
    this.isAdmin = false,
  });

  @override
  State<LoanDetailsPage> createState() => _LoanDetailsPageState();
}

class _LoanDetailsPageState extends State<LoanDetailsPage> {
  bool _isProcessing = false;
  final _currencyFormatter = NumberFormat("#,##0");
  final _dateFormatter = DateFormat("MMMM d, y");

  late Map<String, dynamic> _currentData;
  List<dynamic> _paymentHistory = [];
  Timer? _pollingTimer;

  @override
  void initState() {
    super.initState();
    _currentData = widget.loanData;
    _parsePaymentHistory();
    _startPolling();
  }

  @override
  void dispose() {
    _pollingTimer?.cancel();
    super.dispose();
  }

  void _startPolling() {
    _pollingTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      _refreshData(silent: true);
    });
  }

  void _parsePaymentHistory() {
    if (_currentData.containsKey('payment_history') &&
        _currentData['payment_history']['arrayValue'].containsKey('values')) {
      setState(() {
        _paymentHistory = _currentData['payment_history']['arrayValue']['values'];
      });
    } else {
      setState(() {
        _paymentHistory = [];
      });
    }
  }

  Future<void> _refreshData({bool silent = false}) async {
    final url = Uri.parse(
        'https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents/loan_applications/${widget.loanId}');
    try {
      final response = await Api.get(url);
      if (response.statusCode == 200) {
        if (mounted) {
          setState(() {
            _currentData = jsonDecode(response.body)['fields'];
            _parsePaymentHistory();
          });
        }
      }
    } catch (e) {
      if (!silent) print("Refresh Error: $e");
    }
  }

  // --- LOGIC: MONEY POOL & PAYMENTS ---

  Future<bool> _addToPool(double amount) async {
    final url = Uri.parse(
        'https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents/finance/pool');
    try {
      final response = await Api.get(url);
      if (response.statusCode != 200) throw "Failed to fetch pool";

      final data = jsonDecode(response.body);
      int currentBalance = int.tryParse(
              data['fields']['current_balance']['integerValue'] ?? "0") ??
          0;

      int newBalance = currentBalance + amount.toInt();

      final patchResponse = await Api.patch(
          Uri.parse('$url?updateMask.fieldPaths=current_balance'),
          body: jsonEncode({
            "fields": {
              "current_balance": {"integerValue": newBalance.toString()}
            }
          }));
      return patchResponse.statusCode == 200;
    } catch (e) {
      print("Pool Add Error: $e");
      return false;
    }
  }

  Future<void> _recordPayment(
      {required double amount, required String type, int? monthIndex}) async {
    setState(() => _isProcessing = true);
    try {
      // 1. Add to Pool
      bool poolSuccess = await _addToPool(amount);
      if (!poolSuccess)
        throw "Failed to update money pool. Transaction cancelled.";

      // 2. Create Payment Object
      Map<String, dynamic> newPayment = {
        "mapValue": {
          "fields": {
            "amount": {"integerValue": amount.toInt().toString()},
            "date": {
              "timestampValue": DateTime.now().toUtc().toIso8601String()
            },
            "type": {"stringValue": type},
            "month_index": monthIndex != null
                ? {"integerValue": monthIndex.toString()}
                : {"nullValue": null},
            "recorded_by": {"stringValue": widget.currentUserType}
          }
        }
      };

      // 3. Save to Firestore
      List<dynamic> updatedHistory = List.from(_paymentHistory)..add(newPayment);
      final url = Uri.parse(
          'https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents/loan_applications/${widget.loanId}?updateMask.fieldPaths=payment_history');

      final body = jsonEncode({
        "fields": {
          "payment_history": {
            "arrayValue": {"values": updatedHistory}
          }
        }
      });

      final response = await Api.patch(url, body: body);

      if (response.statusCode == 200) {
        await _refreshData();
        _showSuccess("Payment recorded successfully!");
      } else {
        throw "DB Update Failed: ${response.body}";
      }
    } catch (e) {
      _showError(e.toString());
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  // --- LOGIC: STATUS UPDATES ---

  Future<bool> _deductFromPool(double principalAmount) async {
    final url = Uri.parse(
        'https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents/finance/pool');
    try {
      final response = await Api.get(url);
      if (response.statusCode != 200) throw "Failed to fetch pool";

      final data = jsonDecode(response.body);
      int currentBalance = int.tryParse(
              data['fields']['current_balance']['integerValue'] ?? "0") ??
          0;

      if (currentBalance < principalAmount) {
        _showError("Insufficient funds in Money Pool.");
        return false;
      }

      int newBalance = currentBalance - principalAmount.toInt();
      final patchResponse = await Api.patch(
          Uri.parse('$url?updateMask.fieldPaths=current_balance'),
          body: jsonEncode({
            "fields": {
              "current_balance": {"integerValue": newBalance.toString()}
            }
          }));
      return patchResponse.statusCode == 200;
    } catch (e) {
      _showError("System Error: Pool deduction failed.");
      return false;
    }
  }

  Future<void> _updateStatus(String newStatus, {String? reason}) async {
    setState(() => _isProcessing = true);

    if (newStatus == 'approved') {
      double dbTotal = getRawAmount();
      double principal = ((dbTotal / 1.05) + 0.01).floorToDouble();

      bool poolSuccess = await _deductFromPool(principal);
      if (!poolSuccess) {
        setState(() => _isProcessing = false);
        return;
      }
    }

    String query = "updateMask.fieldPaths=status";
    if (reason != null) query += "&updateMask.fieldPaths=rejection_reason";
    final url = Uri.parse(
        'https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents/loan_applications/${widget.loanId}?$query');
    Map<String, dynamic> fields = {
      "status": {"stringValue": newStatus}
    };
    if (reason != null)
      fields["rejection_reason"] = {"stringValue": reason};

    try {
      await Api.patch(url, body: jsonEncode({"fields": fields}));

      if (newStatus == 'rejected') {
        await _deleteChatHistory();
      }

      if (!mounted) return;
      widget.onUpdate();
      Navigator.pop(context);
    } catch (e) {
      _showError("Error: $e");
    }
    setState(() => _isProcessing = false);
  }

  Future<void> _handleCancel() async {
    bool? confirm = await showDialog(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text("Cancel Application?"),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text("Keep")),
                  TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text("Yes, Cancel"))
                ]));
    if (confirm != true) return;

    setState(() => _isProcessing = true);
    final url = Uri.parse(
        'https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents/loan_applications/${widget.loanId}');
    try {
      await Api.delete(url);
      await _deleteChatHistory();
      if (!mounted) return;
      widget.onUpdate();
      Navigator.pop(context);
    } catch (e) {
      _showError("Error: $e");
    }
    setState(() => _isProcessing = false);
  }

  Future<void> _deleteChatHistory() async {
    String cleanId = widget.loanId.contains('/')
        ? widget.loanId.split('/').last
        : widget.loanId;
    
    try {
      // Fetch all messages in the subcollection and delete them
      var messagesSnapshot = await FirebaseFirestore.instance
          .collection('loan_applications')
          .doc(cleanId)
          .collection('messages')
          .get();
          
      for (var doc in messagesSnapshot.docs) {
        await doc.reference.delete();
      }
    } catch (e) {
      print("Error deleting chat history: $e");
    }
  }

  // --- DIALOGS ---

  void _showCustomPaymentDialog() {
    TextEditingController amountCtrl = TextEditingController();
    showDialog(
        context: context,
        builder: (c) => AlertDialog(
              title: const Text("Record Custom Payment"),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text("Enter amount paid. This will be added to the pool."),
                  const SizedBox(height: 10),
                  TextField(
                      controller: amountCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                          labelText: "Amount (THB)",
                          border: OutlineInputBorder())),
                ],
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(c),
                    child: const Text("Cancel")),
                ElevatedButton(
                  onPressed: () {
                    double? amount =
                        double.tryParse(amountCtrl.text.replaceAll(',', ''));
                    if (amount == null || amount <= 0) {
                      _showError("Invalid amount");
                      return;
                    }
                    Navigator.pop(c);
                    _recordPayment(amount: amount, type: 'custom');
                  },
                  child: const Text("Confirm"),
                )
              ],
            ));
  }

  void _showRejectDialog() {
    TextEditingController reasonController = TextEditingController();
    showDialog(
        context: context,
        builder: (c) => AlertDialog(
                title: const Text("Reject Application"),
                content: TextField(
                    controller: reasonController,
                    decoration:
                        const InputDecoration(hintText: "Reason for rejection")),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(c),
                      child: const Text("Cancel")),
                  ElevatedButton(
                      style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red),
                      onPressed: () {
                        Navigator.pop(c);
                        _updateStatus('rejected',
                            reason: reasonController.text);
                      },
                      child: const Text("Reject",
                          style: TextStyle(color: Colors.white)))
                ]));
  }

  void _showEditDialog(String key, String label, String currentValue) {
    // 1. Clean the initial value to just numbers
    String cleanValue = currentValue.replaceAll(RegExp(r'[^0-9]'), '');
    
    // 2. Pre-fill with commas if it's not empty
    if (cleanValue.isNotEmpty) {
      cleanValue = _currencyFormatter.format(int.parse(cleanValue));
    }

    TextEditingController ctrl = TextEditingController(text: cleanValue);

    showDialog(
        context: context,
        builder: (c) => AlertDialog(
              title: Text("Request Change: $label"),
              content: TextField(
                  controller: ctrl,
                  keyboardType: TextInputType.number,
                  // 3. Add our shiny new comma formatter!
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    CurrencyInputFormatter(), 
                  ],
                  decoration: const InputDecoration(
                      labelText: "New Value", border: OutlineInputBorder())),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(c),
                    child: const Text("Cancel")),
                ElevatedButton(
                    child: const Text("Propose"),
                    onPressed: () {
                      if (ctrl.text.isEmpty) return;
                      Navigator.pop(c);

                      // Remove commas before doing the math
                      String finalValue = ctrl.text.replaceAll(',', '').trim();

                      // Multiply by 1.05 to add the 5% interest for Firestore
                      if (key == 'loan_amount') {
                        double? requestedAmount = double.tryParse(finalValue);
                        if (requestedAmount != null) {
                          finalValue = (requestedAmount * 1.05).ceil().toString(); 
                        }
                      }

                      _sendProposal(key, finalValue, label);
                    })
              ],
            ));
  }

  Future<void> _sendProposal(String key, String value, String label) async {
    String msg = "PROP::$key::$value::$label::PENDING";
    String cleanId = widget.loanId.contains('/')
        ? widget.loanId.split('/').last
        : widget.loanId;

    try {
      // Send the proposal to the NEW Firestore subcollection
      await FirebaseFirestore.instance
          .collection('loan_applications')
          .doc(cleanId)
          .collection('messages')
          .add({
        "text": msg,
        "sender": widget.currentUserType,
        "timestamp": FieldValue.serverTimestamp(),
      });
    } catch (e) {
      _showError("Failed to send proposal: $e");
    }
  }
  // --- HELPERS ---
  void _showError(String msg) {
    if (mounted)
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), backgroundColor: Colors.red));
  }

  void _showSuccess(String msg) {
    if (mounted)
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), backgroundColor: Colors.green));
  }

  String formatDate(String? timestamp) {
    if (timestamp == null) return "N/A";
    try {
      return _dateFormatter.format(DateTime.parse(timestamp));
    } catch (e) {
      return timestamp;
    }
  }

  String getString(String key) {
    final field = _currentData[key];
    if (field == null) return 'N/A';
    return field['stringValue'] ?? field['timestampValue'] ?? 'N/A';
  }

  String getInt(String key) {
    var val = _currentData[key]?['integerValue'];
    if (val == null) return "0";
    if (key == 'months') return int.tryParse(val.toString())?.toString() ?? "0";
    return _currencyFormatter.format(int.tryParse(val.toString()) ?? 0);
  }

  double getRawAmount() =>
      double.tryParse(_currentData['loan_amount']?['integerValue'] ?? '0') ??
      0;
  int getRawMonths() =>
      int.tryParse(_currentData['months']?['integerValue'] ?? '12') ?? 12;
  double getRawSalary() =>
      double.tryParse(_currentData['salary']?['integerValue'] ?? '0') ?? 0;

  // --- INTERACTIVE SCHEDULE WIDGET ---
  Widget _buildInteractiveSchedule() {
    double totalLoan = getRawAmount();
    int months = getRawMonths();
    int salary = getRawSalary().round();

    int baseDeduction = (totalLoan / months).floor();
    int remainder = totalLoan.toInt() - (baseDeduction * months);

    double totalPaid = 0;
    for (var p in _paymentHistory) {
      totalPaid += double.tryParse(
              p['mapValue']['fields']['amount']['integerValue'] ?? '0') ??
          0;
    }
    double remaining = totalLoan - totalPaid;
    bool isFullyPaid = remaining <= 0;

    bool isApproved = getString('status') == 'approved';
    bool isAdmin = widget.isAdmin || widget.currentUserType == 'admin';

    if (isFullyPaid) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.check_circle, size: 80, color: Colors.green),
            const SizedBox(height: 20),
            const Text("Loan Completed!",
                style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87)),
            const SizedBox(height: 10),
            Text("Total Paid: ${_currencyFormatter.format(totalPaid)} THB",
                style: TextStyle(fontSize: 16, color: Colors.grey[600])),
            const SizedBox(height: 30),
          ],
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Card(
            color: Colors.blue[50],
            elevation: 0,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text("Remaining",
                          style: TextStyle(fontSize: 12, color: Colors.grey)),
                      Text(
                          "${_currencyFormatter.format(remaining < 0 ? 0 : remaining)} THB",
                          style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Colors.blue[800])),
                    ],
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      const Text("Paid",
                          style: TextStyle(fontSize: 12, color: Colors.grey)),
                      Text("${_currencyFormatter.format(totalPaid)} THB",
                          style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Colors.green)),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          if (isAdmin && isApproved)
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.add, color: Colors.white),
                label: const Text("Record Custom / Partial Payment",
                    style: TextStyle(color: Colors.white)),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
                onPressed: _showCustomPaymentDialog,
              ),
            ),
          const SizedBox(height: 20),
          const Text("Monthly Schedule",
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 10),
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: months,
            separatorBuilder: (c, i) => const Divider(),
            itemBuilder: (context, index) {
              int monthNum = index + 1;
              int amount = baseDeduction + (index < remainder ? 1 : 0);
              int finalSal = salary - amount;

              bool isPaid = false;
              String paidDate = "";

              for (var p in _paymentHistory) {
                var fields = p['mapValue']['fields'];
                if (fields['type']['stringValue'] == 'monthly' &&
                    fields['month_index'] != null &&
                    int.parse(fields['month_index']['integerValue']) ==
                        monthNum) {
                  isPaid = true;
                  String rawDate = fields['date']['timestampValue'];
                  paidDate =
                      DateFormat("MMM d").format(DateTime.parse(rawDate));
                  break;
                }
              }

              return Container(
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                    color: isPaid
                        ? Colors.green.withOpacity(0.05)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(8)),
                child: Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                          color: Colors.grey[200],
                          borderRadius: BorderRadius.circular(20)),
                      child: Text("$monthNum",
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(width: 15),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text("Deduction: ${_currencyFormatter.format(amount)}",
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold)),
                          Text(
                              "Net Salary: ${_currencyFormatter.format(finalSal)}",
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.grey)),
                        ],
                      ),
                    ),
                    if (isPaid)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          const Icon(Icons.check_circle, color: Colors.green),
                          Text("Paid $paidDate",
                              style: const TextStyle(
                                  fontSize: 10, color: Colors.green)),
                        ],
                      )
                    else if (isAdmin && isApproved)
                      TextButton(
                        onPressed: _isProcessing
                            ? null
                            : () => _recordPayment(
                                amount: amount.toDouble(),
                                type: 'monthly',
                                monthIndex: monthNum),
                        child: const Text("Mark Paid"),
                      )
                    else
                      const Text("Unpaid",
                          style: TextStyle(color: Colors.grey, fontSize: 12)),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    String rawStatus = getString('status').toLowerCase(); 
    String? rejectionReason = _currentData['rejection_reason']?['stringValue'];

    bool isPending = rawStatus == 'pending';
    bool isApproved = rawStatus == 'approved';
    bool isRejected = rawStatus == 'rejected';
    bool isCurrentUserAdmin = widget.currentUserType == 'admin' || widget.isAdmin;
    bool canEdit = isPending;

    // Financial Cals
    double totalLoan = getRawAmount();
    double totalPaid = 0;
    for (var p in _paymentHistory) {
      totalPaid += double.tryParse(
              p['mapValue']['fields']['amount']['integerValue'] ?? '0') ??
          0;
    }
    double remaining = totalLoan - totalPaid;
    bool isFullyPaid = remaining <= 0;

    // Status Logic
    String displayStatus;
    Color statusColor;
    IconData statusIcon;

    if (isApproved) {
      if (isFullyPaid) {
        displayStatus = "COMPLETED";
        statusColor = Colors.green;
        statusIcon = Icons.check_circle;
      } else {
        displayStatus = "ACTIVE (ONGOING)";
        statusColor = Colors.blue.shade700;
        statusIcon = Icons.sync;
      }
    } else if (isRejected) {
      displayStatus = "REJECTED";
      statusColor = Colors.red;
      statusIcon = Icons.cancel;
    } else {
      displayStatus = "PENDING REVIEW";
      statusColor = Colors.orange.shade800;
      statusIcon = Icons.hourglass_top;
    }

    // Chat Logic
    bool chatReadOnly = isRejected || (isApproved && isFullyPaid);

    double dbTotalAmount = getRawAmount();
    double principalAmount = ((dbTotalAmount / 1.05) + 0.01).floorToDouble();
    double interestAmount = dbTotalAmount - principalAmount;

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: Colors.grey[50],
        appBar: AppBar(
          title: const Text("Application Details",
              style: TextStyle(color: Colors.black87)),
          backgroundColor: Colors.white,
          elevation: 0,
          iconTheme: const IconThemeData(color: Colors.black87),
          bottom: const TabBar(
            labelColor: Colors.blue,
            unselectedLabelColor: Colors.grey,
            indicatorColor: Colors.blue,
            tabs: [
              Tab(text: "Details", icon: Icon(Icons.description_outlined)),
              Tab(text: "Schedule", icon: Icon(Icons.table_chart_outlined)),
              Tab(text: "Chat", icon: Icon(Icons.chat_bubble_outline)),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            // --- TAB 1: DETAILS (Wrapped) ---
            KeepAliveWrapper(
              child: SingleChildScrollView(
                key: const PageStorageKey("DetailsTab"), // Extra safety for scrolling
                child: Column(
                  children: [
                    // Status Banner
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          vertical: 16, horizontal: 24),
                      color: statusColor.withOpacity(0.1),
                      child: Row(
                        children: [
                          Icon(statusIcon, color: statusColor, size: 28),
                          const SizedBox(width: 16),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                displayStatus,
                                style: TextStyle(
                                    color: statusColor,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                    letterSpacing: 0.5),
                              ),
                              if (isRejected && rejectionReason != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text("Reason: $rejectionReason",
                                      style: TextStyle(
                                          color: statusColor, fontSize: 12)),
                                ),
                              if (isApproved && !isFullyPaid)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text("Repayment in progress",
                                      style: TextStyle(
                                          color: statusColor, fontSize: 12)),
                                ),
                            ],
                          )
                        ],
                      ),
                    ),

                    // Main Details Card
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        children: [
                          Card(
                            elevation: 2,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                            color: Colors.white,
                            child: Padding(
                              padding: const EdgeInsets.all(20),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text("Financial Breakdown",
                                      style: TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.bold)),
                                  const SizedBox(height: 16),
                                  
                                  // Receipt Box
                                  Container(
                                    padding: const EdgeInsets.all(16),
                                    decoration: BoxDecoration(
                                      color: Colors.grey[50],
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(color: Colors.grey.shade200),
                                    ),
                                    child: Column(
                                      children: [
                                        _row("Requested Amount",
                                            "${_currencyFormatter.format(principalAmount)} THB",
                                            "loan_amount",
                                            canEdit,
                                            rawValue:
                                                principalAmount.toStringAsFixed(0)),
                                        const Divider(),
                                        _row("Interest (5% Flat)",
                                            "+${_currencyFormatter.format(interestAmount)} THB",
                                            "",
                                            false,
                                            valueColor: Colors.orange[800]),
                                        const Divider(),
                                        _row("Total Repayment Amount",
                                            "${_currencyFormatter.format(dbTotalAmount)} THB",
                                            "",
                                            false,
                                            isBold: true,
                                            isLarge: true),
                                      ],
                                    ),
                                  ),

                                  const SizedBox(height: 24),
                                  const Text("Loan Configuration",
                                      style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600)),
                                  const SizedBox(height: 12),
                                  _row("Duration", "${getInt('months')} Months",
                                      "months", canEdit,
                                      rawValue: getInt('months')),
                                  _row("Monthly Repayment", 
                                    "~${_currencyFormatter.format(dbTotalAmount / getRawMonths())} THB", 
                                    "", false),
                                  
                                  const Divider(height: 32),
                                  
                                  const Text("Applicant Details",
                                      style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600)),
                                  const SizedBox(height: 12),
                                  _row("Reported Income", "${getInt('salary')} THB",
                                      "salary", false),
                                  _row("Purpose", getString('reason'), "reason",
                                      false),
                                  _row("Application Date",
                                      formatDate(getString('timestamp')), "", false),
                                ],
                              ),
                            ),
                          ),

                          const SizedBox(height: 30),

                          // BUTTONS
                          if (isPending) ...[
                            if (isCurrentUserAdmin)
                              Row(children: [
                                Expanded(
                                    child: ElevatedButton.icon(
                                  onPressed: _isProcessing
                                      ? null
                                      : () => _updateStatus('approved'),
                                  icon: const Icon(Icons.check,
                                      color: Colors.white),
                                  label: const Text("Approve",
                                      style: TextStyle(color: Colors.white)),
                                  style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.green,
                                      padding: const EdgeInsets.symmetric(vertical: 12)),
                                )),
                                const SizedBox(width: 12),
                                Expanded(
                                    child: ElevatedButton.icon(
                                  onPressed:
                                      _isProcessing ? null : _showRejectDialog,
                                  icon: const Icon(Icons.close,
                                      color: Colors.white),
                                  label: const Text("Reject",
                                      style: TextStyle(color: Colors.white)),
                                  style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.red,
                                      padding: const EdgeInsets.symmetric(vertical: 12)),
                                )),
                              ])
                            else
                              SizedBox(
                                width: double.infinity,
                                child: OutlinedButton(
                                  onPressed:
                                      _isProcessing ? null : _handleCancel,
                                  style: OutlinedButton.styleFrom(
                                      side: const BorderSide(color: Colors.red),
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 12)),
                                  child: const Text("Cancel Application",
                                      style: TextStyle(color: Colors.red)),
                                ),
                              )
                          ],
                          const SizedBox(height: 50),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // --- TAB 2: SCHEDULE (Wrapped) ---
            KeepAliveWrapper(
              child: SingleChildScrollView( // Wrapped in ScrollView to ensure scrolling works
                key: const PageStorageKey("ScheduleTab"),
                child: _buildInteractiveSchedule(),
              ),
            ),

            // --- TAB 3: CHAT (Wrapped) ---
            KeepAliveWrapper(
              child: Padding(
                padding: const EdgeInsets.only(top: 20),
                child: ChatWidget(
                  loanId: widget.loanId,
                  currentSender: widget.currentUserType,
                  isReadOnly: chatReadOnly,
                  onRefreshDetails: _refreshData,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value, String key, bool canEdit,
      {bool isBold = false,
      bool isLarge = false,
      Color? valueColor,
      String? rawValue}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(label, style: TextStyle(color: Colors.grey[600], fontSize: 14)),
          ),
          Row(
            children: [
              Text(
                value,
                style: TextStyle(
                  fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
                  fontSize: isLarge ? 18 : 14,
                  color: valueColor ?? Colors.black87,
                ),
              ),
              if (canEdit)
                GestureDetector(
                  onTap: () => _showEditDialog(key, label, rawValue ?? value),
                  child: Padding(
                    padding: const EdgeInsets.only(left: 8.0),
                    child: Icon(Icons.edit, size: 16, color: Colors.blue[300]),
                  ),
                )
            ],
          )
        ],
      ),
    );
  }
}

class KeepAliveWrapper extends StatefulWidget {
  final Widget child;
  const KeepAliveWrapper({super.key, required this.child});

  @override
  State<KeepAliveWrapper> createState() => _KeepAliveWrapperState();
}

class _KeepAliveWrapperState extends State<KeepAliveWrapper> with AutomaticKeepAliveClientMixin {
  @override
  Widget build(BuildContext context) {
    super.build(context); // This must be called
    return widget.child;
  }

  @override
  bool get wantKeepAlive => true; // This keeps the state alive
}

class CurrencyInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    if (newValue.text.isEmpty) return newValue;
    
    // Strip out non-numbers, parse, and format with commas
    int value = int.tryParse(newValue.text.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
    String newText = NumberFormat("#,##0").format(value);
    
    return newValue.copyWith(
      text: newText,
      selection: TextSelection.collapsed(offset: newText.length),
    );
  }
}