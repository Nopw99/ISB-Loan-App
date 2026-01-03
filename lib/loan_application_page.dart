import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:http/http.dart' as http; // For your REST API
import 'dart:convert';
import 'secrets.dart';

class LoanApplicationPage extends StatefulWidget {
  final VoidCallback onBackTap;
  final double initialSalary;
  final String userEmail;

  const LoanApplicationPage({
    super.key,
    required this.onBackTap,
    required this.initialSalary,
    required this.userEmail,
  });

  @override
  State<LoanApplicationPage> createState() => _LoanApplicationPageState();
}

class _LoanApplicationPageState extends State<LoanApplicationPage> {
  // Controllers
  final TextEditingController _loanAmountController = TextEditingController();
  final TextEditingController _monthsController = TextEditingController();
  final TextEditingController _reasonController = TextEditingController();

  List<Map<String, dynamic>> _paymentSchedule = [];

  // State Flags
  bool _isCostTooHigh = false;
  bool _isLoanTooHigh = false;
  bool _isDurationTooLong = false;
  bool _isSubmitting = false; // Loading spinner state

  // Footer Totals
  double _totalSalary = 0;
  double _totalLoanCost = 0;
  double _totalFinalSalary = 0;

  final NumberFormat _formatter = NumberFormat("#,##0");

  @override
  void initState() {
    super.initState();
    _loanAmountController.addListener(_calculateLoan);
    _monthsController.addListener(_calculateLoan);
  }

  @override
  void dispose() {
    _loanAmountController.dispose();
    _monthsController.dispose();
    _reasonController.dispose();
    super.dispose();
  }

  // --- 1. VALIDATE AND SHOW DIALOG ---
  void _confirmSubmission() {
    // Basic Validation
    if (_loanAmountController.text.isEmpty || _monthsController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please fill in all fields")),
      );
      return;
    }

    // Error Validation
    if (_paymentSchedule.isEmpty || _isCostTooHigh || _isLoanTooHigh) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please fix the errors in your application first.")),
      );
      return;
    }

    // IF VALID -> SHOW TERMS DIALOG
    showDialog(
      context: context,
      builder: (context) {
        final ScrollController termsController = ScrollController();

        return AlertDialog(
          title: const Text("Terms and Agreements"),
          content: Scrollbar(
            thumbVisibility: true,
            controller: termsController,
            child: SingleChildScrollView(
              controller: termsController,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    "Please read the following terms carefully before submitting your loan application.",
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    termsandservice,
                    style: TextStyle(fontSize: 13, color: Colors.grey[800]),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Disagree", style: TextStyle(color: Colors.red)),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                _uploadApplication();
              },
              style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
              child: const Text("I Agree", style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  // --- 2. THE ACTUAL API SUBMIT FUNCTION ---
  Future<void> _uploadApplication() async {
    setState(() => _isSubmitting = true);

    // Prepare API Data
    const String collection = "loan_applications";

    final url = Uri.parse(
        'https://firestore.googleapis.com/v1/projects/$projectId/databases/(default)/documents/$collection');

    // 1. Get raw input
    double rawAmount = double.tryParse(_loanAmountController.text.replaceAll(',', '')) ?? 0;
    String cleanMonths = _monthsController.text.replaceAll(',', '');

    // 2. Apply 5% Interest Calculation for the Database
    // CHANGED: used .ceil() to round UP if there is a decimal
    int totalLoanWithInterest = (rawAmount * 1.05).ceil();

    try {
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          "fields": {
            "email": {"stringValue": widget.userEmail.trim()},
            // Send the 105% amount to the database
            "loan_amount": {"integerValue": totalLoanWithInterest.toString()},
            "months": {"integerValue": cleanMonths.toString()},
            "salary": {"integerValue": widget.initialSalary.toStringAsFixed(0)},
            "reason": {"stringValue": _reasonController.text},
            "status": {"stringValue": "pending"},
            "timestamp": {"timestampValue": DateTime.now().toUtc().toIso8601String()},
            "is_hidden": {"booleanValue": false},
          }
        }),
      );

      if (response.statusCode == 200) {
        if (!mounted) return;

        // 1. Show Success Message
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Application Submitted Successfully!"),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2), // Keep it short
          ),
        );

        // 2. Clear form (Good practice)
        _loanAmountController.clear();
        _monthsController.clear();
        _reasonController.clear();
        setState(() => _paymentSchedule = []);

        // 3. AUTOMATICALLY GO BACK TO HOMEPAGE
        widget.onBackTap();
      } else {
        print("Failed: ${response.body}");
        throw Exception("Server Error: ${response.statusCode}");
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Error: $e"), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  void _calculateLoan() {
    double salary = widget.initialSalary;
    double rawLoanAmount = double.tryParse(_loanAmountController.text.replaceAll(',', '')) ?? 0;
    int months = int.tryParse(_monthsController.text.replaceAll(',', '')) ?? 0;

    setState(() {
      _isCostTooHigh = false;
      _isLoanTooHigh = false;
      _isDurationTooLong = false;
      _totalSalary = 0;
      _totalLoanCost = 0;
      _totalFinalSalary = 0;
    });

    if (rawLoanAmount <= 0 || months <= 0) {
      if (_paymentSchedule.isNotEmpty) setState(() => _paymentSchedule = []);
      return;
    }

    if (months > 12) {
      setState(() {
        _paymentSchedule = [];
        _isDurationTooLong = true;
      });
      return;
    }

    // --- UPDATED LOGIC: Apply 5% Interest ---
    double totalLoanAmountWithInterest = rawLoanAmount * 1.05;

    // Check: Principal Loan cannot exceed MONTHLY salary (using raw amount for this check typically)
    if (rawLoanAmount > salary) {
      setState(() {
        _paymentSchedule = [];
        _isLoanTooHigh = true;
      });
      return;
    }

    // CHANGED: used .ceil() to round UP the total loan amount
    int totalLoanInt = totalLoanAmountWithInterest.ceil();
    
    int baseDeduction = (totalLoanInt / months).floor();
    int remainder = totalLoanInt - (baseDeduction * months);

    // Final check to ensure deduction doesn't exceed salary
    if (baseDeduction > salary) {
      setState(() {
        _paymentSchedule = [];
        _isCostTooHigh = true;
      });
      return;
    }

    List<Map<String, dynamic>> newSchedule = [];
    double tempTotalLoan = 0;

    for (int i = 0; i < months; i++) {
      int currentDeduction = baseDeduction + (i < remainder ? 1 : 0);
      double finalSal = salary - currentDeduction;
      tempTotalLoan += currentDeduction;
      newSchedule.add({
        'month': i + 1,
        'salary': salary,
        'deduction': currentDeduction.toDouble(),
        'final': finalSal,
      });
    }

    setState(() {
      _paymentSchedule = newSchedule;
      _totalSalary = salary * months;
      _totalLoanCost = tempTotalLoan;
      _totalFinalSalary = _totalSalary - _totalLoanCost;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: AppBar(
        title: const Text("Apply for Loan", style: TextStyle(color: Colors.black)),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.black),
          onPressed: widget.onBackTap,
        ),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          bool isSmallScreen = constraints.maxWidth < 900;
          if (isSmallScreen) {
            return SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  _buildInputForm(),
                  const SizedBox(height: 24),
                  SizedBox(height: 500, child: _buildResultTable()),
                ],
              ),
            );
          } else {
            return Padding(
              padding: const EdgeInsets.all(24.0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 4, child: _buildInputForm()),
                  const SizedBox(width: 24),
                  Expanded(flex: 6, child: _buildResultTable()),
                ],
              ),
            );
          }
        },
      ),
    );
  }

  Widget _buildInputForm() {
    bool isFormValid = _paymentSchedule.isNotEmpty &&
        !_isLoanTooHigh &&
        !_isDurationTooLong &&
        !_isCostTooHigh;

    return Card(
      elevation: 5,
      color: Colors.white,
      surfaceTintColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Loan Details",
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            const SizedBox(height: 20),

            // Salary Display
            Container(
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
              width: double.infinity,
              decoration: BoxDecoration(
                color: Colors.grey[100],
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("Monthly Salary",
                      style: TextStyle(
                          color: Colors.grey[600],
                          fontSize: 14,
                          fontWeight: FontWeight.w500)),
                  const SizedBox(height: 4),
                  Text("${_formatter.format(widget.initialSalary)} Baht",
                      style: const TextStyle(
                          color: Colors.black,
                          fontSize: 18,
                          fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            const SizedBox(height: 16),
            
            // --- UPDATED: Text Field with Interest Notice ---
            _buildTextField("Loan Amount (Baht)", _loanAmountController),
            const SizedBox(height: 6),
            const Padding(
              padding: EdgeInsets.only(left: 4.0),
              child: Text(
                "Loan amount is subject to 5% interest",
                style: TextStyle(color: Colors.grey, fontSize: 12, fontStyle: FontStyle.italic),
              ),
            ),
            // ------------------------------------------------

            const SizedBox(height: 16),
            _buildTextField("Duration (Months)", _monthsController,
                isCurrency: false),
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 16),
            const Text("Reason for Loan",
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            TextField(
              controller: _reasonController,
              maxLines: 4,
              decoration: InputDecoration(
                hintText: "Please describe why you need this loan.",
                hintStyle: TextStyle(color: Colors.grey[400]),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                filled: true,
                fillColor: Colors.grey[50],
              ),
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                // Trigger the Dialog function first!
                onPressed: (isFormValid && !_isSubmitting)
                    ? _confirmSubmission
                    : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green[600],
                  disabledBackgroundColor: Colors.grey[300],
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: _isSubmitting
                    ? const SizedBox(
                        height: 24,
                        width: 24,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2))
                    : const Text("Submit Application",
                        style: TextStyle(
                            fontSize: 18,
                            color: Colors.white,
                            fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResultTable() {
    return Card(
      elevation: 5,
      color: Colors.white,
      surfaceTintColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Payment Schedule",
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
              decoration: BoxDecoration(
                  color: Colors.grey[100], borderRadius: BorderRadius.circular(8)),
              child: Row(
                children: const [
                  Expanded(
                      child: Text('Month',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontWeight: FontWeight.bold))),
                  Expanded(
                      child: Text('Salary',
                          textAlign: TextAlign.right,
                          style: TextStyle(fontWeight: FontWeight.bold))),
                  Expanded(
                      child: Text('Loan Payment',
                          textAlign: TextAlign.right,
                          style: TextStyle(
                              fontWeight: FontWeight.bold, color: Colors.red))),
                  Expanded(
                      child: Text('Final Salary',
                          textAlign: TextAlign.right,
                          style: TextStyle(
                              fontWeight: FontWeight.bold, color: Colors.green))),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Expanded(child: _buildContentArea()),
            if (_paymentSchedule.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                decoration: BoxDecoration(
                  color: Colors.blue[50],
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.blue.shade100),
                ),
                child: Row(
                  children: [
                    Expanded(
                        child: Text("${_monthsController.text} Months",
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 16))),
                    Expanded(
                        child: Text(_formatter.format(_totalSalary),
                            textAlign: TextAlign.right,
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 16))),
                    Expanded(
                        child: Text("-${_formatter.format(_totalLoanCost)}",
                            textAlign: TextAlign.right,
                            style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.red,
                                fontSize: 16))),
                    Expanded(
                        child: Text(_formatter.format(_totalFinalSalary),
                            textAlign: TextAlign.right,
                            style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.green,
                                fontSize: 16))),
                  ],
                ),
              ),
            ]
          ],
        ),
      ),
    );
  }

  Widget _buildContentArea() {
    if (_isDurationTooLong) {
      return Center(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.calendar_month_rounded, size: 48, color: Colors.orange[400]),
        const SizedBox(height: 16),
        Text("Duration cannot exceed 12 months",
            style: TextStyle(
                color: Colors.orange[600],
                fontSize: 18,
                fontWeight: FontWeight.w600))
      ]));
    }
    if (_isLoanTooHigh) {
      return Center(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.money_off_csred_rounded, size: 48, color: Colors.orange[400]),
        const SizedBox(height: 16),
        Text("Loan cannot exceed monthly salary",
            style: TextStyle(
                color: Colors.orange[600],
                fontSize: 18,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Text("(Limit: ${_formatter.format(widget.initialSalary)} baht)",
            style: TextStyle(color: Colors.orange[300], fontSize: 14))
      ]));
    }
    if (_isCostTooHigh) {
      return Center(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.warning_amber_rounded, size: 48, color: Colors.red[300]),
        const SizedBox(height: 16),
        Text("Cost is more than monthly payment",
            style: TextStyle(
                color: Colors.red[400],
                fontSize: 18,
                fontWeight: FontWeight.w600))
      ]));
    }
    if (_paymentSchedule.isEmpty) {
      return Center(
          child: Text("Enter details to see breakdown.",
              style: TextStyle(color: Colors.grey[500], fontSize: 16)));
    }
    return ListView.separated(
      itemCount: _paymentSchedule.length,
      separatorBuilder: (ctx, index) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final item = _paymentSchedule[index];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          child: Row(
            children: [
              Expanded(
                  child: Text("${item['month']}", textAlign: TextAlign.center)),
              Expanded(
                  child: Text(_formatter.format(item['salary']),
                      textAlign: TextAlign.right)),
              Expanded(
                  child: Text("-${_formatter.format(item['deduction'])}",
                      textAlign: TextAlign.right,
                      style: const TextStyle(color: Colors.red))),
              Expanded(
                  child: Text(_formatter.format(item['final']),
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, color: Colors.green))),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTextField(String label, TextEditingController controller,
      {bool isCurrency = true}) {
    return TextField(
      controller: controller,
      keyboardType: TextInputType.number,
      inputFormatters: isCurrency
          ? [FilteringTextInputFormatter.digitsOnly, CurrencyInputFormatter()]
          : [FilteringTextInputFormatter.digitsOnly],
      style: const TextStyle(color: Colors.black),
      decoration: InputDecoration(
        labelText: label,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        filled: true,
        fillColor: Colors.grey[50],
      ),
    );
  }
}

class CurrencyInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    if (newValue.selection.baseOffset == 0) return newValue;
    // Just remove commas to parse
    String cleanText = newValue.text.replaceAll(',', '');
    if (cleanText.isEmpty) return newValue;

    double value = double.parse(cleanText);
    final formatter = NumberFormat('#,###');
    String newText = formatter.format(value);

    return newValue.copyWith(
        text: newText,
        selection: TextSelection.collapsed(offset: newText.length));
  }
}