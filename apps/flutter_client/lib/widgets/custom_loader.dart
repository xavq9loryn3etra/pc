import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

class CustomLoader extends StatelessWidget {
  final double size;

  const CustomLoader({
    super.key,
    this.size = 200.0,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Lottie.asset(
        'assets/loader.json',
        width: size,
        height: size,
        fit: BoxFit.contain,
      ),
    );
  }
}
