import 'package:flutter/material.dart';
import 'package:flutter_client/models/movie.dart';
import 'package:flutter_client/screens/details_screen.dart';

class DesktopDetailsPanel extends StatelessWidget {
  final Movie movie;
  final VoidCallback onClose;

  const DesktopDetailsPanel({
    Key? key,
    required this.movie,
    required this.onClose,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 700, // Fixed width
      height: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF141414), // Matches app background
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.5),
            blurRadius: 30,
            spreadRadius: 5,
            offset: const Offset(-5, 0),
          ),
        ],
        border: const Border(left: BorderSide(color: Colors.white10, width: 1)),
      ),
      child: ClipRect(
        child: DetailsScreen(
          movie: movie,
          isSidePanel: true,
          onClose: onClose,
          heroTag: 'side_panel_${movie.id}', // Avoid hero conflicts
        ),
      ),
    );
  }
}
