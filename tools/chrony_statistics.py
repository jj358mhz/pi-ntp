#!/usr/bin/env python3
"""
chrony_statistics.py — Parse and plot chrony statistics log

Usage:
    python3 chrony_statistics.py

Reads chrony_statistics.log from the current directory and produces:
  - Summary statistics (avg, median, min, max offset per IP)
  - A matplotlib plot of estimated offset over time per upstream server

The chrony statistics log is typically found at /var/log/chrony/statistics.
PPS entries are excluded — this tool is focused on upstream NTP server behavior.

Setup:
    python3 -m venv venv
    source venv/bin/activate
    pip install -r requirements.txt
    python3 chrony_statistics.py
"""

import os
import sys
import pandas as pd
import matplotlib.pyplot as plt
from io import StringIO


def parse_chrony_stats(file_path):
    """
    Parse chrony statistics log file and return a pandas DataFrame.
    Skips header/separator lines and PPS entries.
    """
    with open(file_path, 'r') as f:
        file_contents = f.readlines()

    # Skip header/separator lines
    file_contents = [line for line in file_contents
                     if not line.startswith('=') and not line.startswith(' ')]

    # Exclude PPS lines (focus on upstream NTP servers)
    file_contents = [line for line in file_contents if 'PPS' not in line]

    csv_data = StringIO(''.join(file_contents))

    df = pd.read_csv(
        csv_data,
        sep=r'\s+',
        names=['Date', 'Time', 'IP_Address', 'Std_dev', 'Est_offset', 'Offset_sd',
               'Diff_freq', 'Est_skew', 'Stress', 'Ns', 'Bs', 'Nr', 'Asym']
    )

    df['timestamp'] = pd.to_datetime(df['Date'] + ' ' + df['Time'])
    return df


def plot_est_offset(df):
    """
    Plot estimated offset vs time for each upstream IP address.
    """
    plt.figure(figsize=(12, 6))

    for ip in df['IP_Address'].unique():
        ip_data = df[df['IP_Address'] == ip]
        plt.plot(ip_data['timestamp'], ip_data['Est_offset'],
                 marker='o', label=ip, linestyle='-', markersize=4)

    plt.xlabel('Time')
    plt.ylabel('Estimated Offset (seconds)')
    plt.title('Chrony Estimated Offset Over Time by NTP Server')
    plt.legend()
    plt.grid(True)
    plt.xticks(rotation=45)
    plt.tight_layout()

    return plt


def analyze_chrony_stats(file_path):
    """
    Main analysis function. Returns DataFrame, summary dict, and plot.
    """
    df = parse_chrony_stats(file_path)

    summary = {
        'IP Addresses': df['IP_Address'].nunique(),
        'Time Range': f"{df['timestamp'].min()} to {df['timestamp'].max()}",
        'Average Est Offset by IP': df.groupby('IP_Address')['Est_offset'].mean().to_dict(),
        'Max Est Offset by IP':     df.groupby('IP_Address')['Est_offset'].max().to_dict(),
        'Min Est Offset by IP':     df.groupby('IP_Address')['Est_offset'].min().to_dict(),
        'Median Est Offset by IP':  df.groupby('IP_Address')['Est_offset'].median().to_dict(),
    }

    plot = plot_est_offset(df)
    return df, summary, plot


if __name__ == "__main__":
    file_path = "chrony_statistics.log"

    if not os.path.exists(file_path):
        print(f"Error: {file_path} not found. Copy it from /var/log/chrony/statistics on the NTP server.")
        sys.exit(1)

    df, summary, plot = analyze_chrony_stats(file_path)

    print("\nChrony Statistics Summary:")
    print("-" * 30)
    print(f"Number of IP Addresses: {summary['IP Addresses']}")
    print(f"Time Range: {summary['Time Range']}")

    print("\nAverage Estimated Offset by IP:")
    for ip, avg in summary['Average Est Offset by IP'].items():
        print(f"  {ip}: {avg:.2e}")

    print("\nMedian Estimated Offset by IP:")
    for ip, median in summary['Median Est Offset by IP'].items():
        print(f"  {ip}: {median:.2e}")

    plt.show()
