#!/usr/bin/env python3
"""
USBGuard Test Suite - Shared Configuration
Pytest configuration and shared fixtures.
"""
import os
import sys
import tempfile

# Ensure project root is in path
PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
sys.path.insert(0, os.path.join(PROJECT_ROOT, 'web'))
sys.path.insert(0, PROJECT_ROOT)