//
//  Viewer.swift
//  Oblivion
//
//  Created by Jason Phan on 2026-10-05.
//
import UIKit

class Viewer: UIViewController {
    @IBOutlet weak var pageCollectionView: UICollectionView!
    
    @IBOutlet weak var topBarView: UIView!
    @IBOutlet weak var bottomBarView: UIView!
    
    @IBOutlet weak var fileNameLabel: UILabel!
    
    @IBOutlet weak var pageCountLabel: UILabel!
    
    @IBAction func showDocumentActions(_ sender: Any) {
    }
}
